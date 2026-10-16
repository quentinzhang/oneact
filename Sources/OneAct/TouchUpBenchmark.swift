import CoreImage
import CoreVideo
import Foundation
import Metal
import QuartzCore
import Vision

/// `--touch-up-bench`: per-frame cost of the real compositor calls, with and
/// without touch-up, at 1080p and 1440p, in Camera and Screen + Camera
/// (cutout, blur layout) mode. No camera or screen is captured — the frames
/// are synthetic at real sizes — so it runs anywhere and measures the part of
/// the frame budget that touch-up adds.
///
/// `--touch-up-still <image> <out.png> [--max]`: runs face detection and
/// touch-up on a photo and writes before | after side by side, for checking
/// the look on a real face without a camera.
enum TouchUpBenchmark {
    private struct Case {
        let name: String
        let cameraWidth: Int
        let cameraHeight: Int
        let canvasWidth: Int
        let canvasHeight: Int
        let screen: Bool
    }

    private static let cases = [
        Case(name: "camera 1080p", cameraWidth: 1_920, cameraHeight: 1_080, canvasWidth: 1_920, canvasHeight: 1_080, screen: false),
        Case(name: "camera 1440p", cameraWidth: 3_840, cameraHeight: 2_160, canvasWidth: 2_560, canvasHeight: 1_440, screen: false),
        Case(name: "screen+cutout 1080p", cameraWidth: 1_920, cameraHeight: 1_080, canvasWidth: 1_920, canvasHeight: 1_080, screen: true),
        Case(name: "screen+cutout 1440p", cameraWidth: 1_920, cameraHeight: 1_080, canvasWidth: 2_560, canvasHeight: 1_440, screen: true),
        Case(name: "screen+cutout 1440p 4K-cam", cameraWidth: 3_840, cameraHeight: 2_160, canvasWidth: 2_560, canvasHeight: 1_440, screen: true)
    ]

    static func run() -> Int32 {
        guard let device = MTLCreateSystemDefaultDevice(), TouchUp.isAvailable else {
            fputs("TOUCH_UP_BENCH_FAILED kernels unavailable\n", stderr)
            return 1
        }
        let context = CIContext(mtlDevice: device)
        print("TOUCH_UP_BENCH device=\(device.name) frames=240 budget=33.3ms")
        do {
            for benchCase in cases {
                let camera = try syntheticCamera(width: benchCase.cameraWidth, height: benchCase.cameraHeight, context: context)
                let screen = benchCase.screen ? try syntheticScreen(context: context) : nil
                let mask = benchCase.screen ? try personMask() : nil
                // Smoothing at the top of its range does the most work; the
                // face is placed where the synthetic patch puts it.
                let settings = TouchUpSettings(enabled: true, light: 1, warmth: 0.5, smooth: 1)
                let off = try measure(benchCase, camera: camera, screen: screen, mask: mask, settings: nil, context: context)
                let on = try measure(benchCase, camera: camera, screen: screen, mask: mask, settings: settings, context: context)
                print(String(
                    format: "TOUCH_UP_BENCH case=\"%@\" camera=%dx%d canvas=%dx%d off_ms=%.2f(p95 %.2f, gpu %.2f) on_ms=%.2f(p95 %.2f, gpu %.2f) added_ms=%.2f",
                    benchCase.name, benchCase.cameraWidth, benchCase.cameraHeight,
                    benchCase.canvasWidth, benchCase.canvasHeight,
                    off.mean, off.p95, off.gpu, on.mean, on.p95, on.gpu, on.mean - off.mean
                ))
            }
            try measureDetection(context: context)
            try measureSustained(context: context)
        } catch {
            fputs("TOUCH_UP_BENCH_FAILED \(error.localizedDescription)\n", stderr)
            return 1
        }
        return 0
    }

    // MARK: - Frames

    /// The synthetic face patch, scaled up so the face covers about a fifth of
    /// the frame width — a typical talking-head framing.
    private static func syntheticCamera(width: Int, height: Int, context: CIContext) throws -> CVPixelBuffer {
        let face = TouchUpSelfTest.SyntheticFace.make().image
        let scale = CGFloat(width) * 1.0 / CGFloat(TouchUpSelfTest.SyntheticFace.width)
        let scaled = face.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let offsetY = (scaled.extent.height - CGFloat(height)) / 2
        let image = scaled.transformed(by: CGAffineTransform(translationX: 0, y: -offsetY))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let buffer = try pixelBuffer(width: width, height: height)
        context.render(image, to: buffer)
        return buffer
    }

    /// The face box of `syntheticCamera`, in its normalized coordinates.
    private static func syntheticFaceBox(width: Int, height: Int) -> CGRect {
        let source = TouchUpSelfTest.SyntheticFace.self
        let scale = CGFloat(width) / CGFloat(source.width)
        let offsetY = (CGFloat(source.height) * scale - CGFloat(height)) / 2
        let box = source.box
        return CGRect(
            x: box.minX,
            y: (box.minY * CGFloat(source.height) * scale - offsetY) / CGFloat(height),
            width: box.width,
            height: box.height * CGFloat(source.height) * scale / CGFloat(height)
        )
    }

    /// A busy desktop-sized frame at a 16-inch MacBook Pro's native size.
    private static func syntheticScreen(context: CIContext) throws -> CVPixelBuffer {
        let width = 3_456, height = 2_234
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputColor0": CIColor(red: 0.95, green: 0.95, blue: 0.97),
            "inputColor1": CIColor(red: 0.2, green: 0.3, blue: 0.5),
            "inputWidth": 24
        ])?.outputImage ?? CIImage(color: .gray)
        let buffer = try pixelBuffer(width: width, height: height)
        context.render(checker.cropped(to: CGRect(x: 0, y: 0, width: width, height: height)), to: buffer)
        return buffer
    }

    /// Vision's balanced person mask is 512 × 384; a person in the middle.
    private static func personMask() throws -> CIImage {
        CIImage(color: .white)
            .cropped(to: CGRect(x: 150, y: 0, width: 212, height: 330))
            .composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 512, height: 384)))
    }

    private static func pixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else {
            throw NSError(domain: "OneAct.TouchUpBench", code: 1, userInfo: [NSLocalizedDescriptionKey: "pixel buffer"])
        }
        return buffer
    }

    // MARK: - Measurement

    private struct Timing {
        var mean: Double
        var p95: Double
        var gpu: Double
    }

    /// One frame exactly as the recorder builds it, rendered to a canvas
    /// buffer and waited on, so the time includes the GPU finishing.
    private static func compose(
        _ benchCase: Case,
        camera: CVPixelBuffer,
        screen: CVPixelBuffer?,
        mask: CIImage?,
        settings: TouchUpSettings?
    ) -> CIImage {
        var cameraImage = CIImage(cvPixelBuffer: camera)
        if let settings {
            let face = FaceRegion(box: syntheticFaceBox(width: benchCase.cameraWidth, height: benchCase.cameraHeight), presence: 1)
            cameraImage = TouchUp.apply(settings, to: cameraImage, face: face)
        }
        guard let screen, let mask else {
            return FrameCompositor.aspectFill(cameraImage, width: benchCase.canvasWidth, height: benchCase.canvasHeight)
        }
        return FrameCompositor.screenWithCamera(
            screen: CIImage(cvPixelBuffer: screen),
            camera: FrameCompositor.personCutout(camera: cameraImage, mask: mask),
            width: benchCase.canvasWidth,
            height: benchCase.canvasHeight,
            cameraZoom: 1,
            position: .bottomRight,
            screenLayout: .blur,
            cameraFrame: .cutout,
            cameraScale: 1.6,
            personBox: CGRect(x: 0.29, y: 0, width: 0.41, height: 0.86)
        )
    }

    private static func measure(
        _ benchCase: Case,
        camera: CVPixelBuffer,
        screen: CVPixelBuffer?,
        mask: CIImage?,
        settings: TouchUpSettings?,
        context: CIContext
    ) throws -> Timing {
        let output = try pixelBuffer(width: benchCase.canvasWidth, height: benchCase.canvasHeight)
        var wall: [Double] = []
        var gpu: [Double] = []
        for frame in 0..<270 {
            touch(camera, frame: frame)
            if let screen { touch(screen, frame: frame) }
            let start = CACurrentMediaTime()
            let image = compose(benchCase, camera: camera, screen: screen, mask: mask, settings: settings)
            let destination = CIRenderDestination(pixelBuffer: output)
            destination.colorSpace = VideoEncoding.colorSpace
            let info = try context.startTask(
                toRender: image,
                from: CGRect(x: 0, y: 0, width: benchCase.canvasWidth, height: benchCase.canvasHeight),
                to: destination,
                at: .zero
            ).waitUntilCompleted()
            // The first frames compile and cache pipelines; they are not
            // what a running preview pays.
            guard frame >= 30 else { continue }
            wall.append((CACurrentMediaTime() - start) * 1_000)
            gpu.append(info.kernelExecutionTime * 1_000)
        }
        wall.sort()
        return Timing(
            mean: wall.reduce(0, +) / Double(wall.count),
            p95: wall[Int(Double(wall.count) * 0.95)],
            gpu: gpu.reduce(0, +) / Double(gpu.count)
        )
    }

    /// The face queue's work for one detection: the low-resolution copy plus
    /// Vision. It runs beside the compositor, at most 15 times a second.
    private static func measureDetection(context: CIContext) throws {
        for (width, height) in [(1_920, 1_080), (3_840, 2_160)] {
            let buffer = try syntheticCamera(width: width, height: height, context: context)
            let tracker = FaceRegionTracker(context: context)
            var times: [Double] = []
            for run in 0..<40 {
                let start = CACurrentMediaTime()
                _ = tracker.detectSynchronously(in: buffer)
                if run >= 5 { times.append((CACurrentMediaTime() - start) * 1_000) }
            }
            times.sort()
            print(String(
                format: "TOUCH_UP_BENCH face_detection camera=%dx%d input=%d-px-long-side mean_ms=%.2f p95_ms=%.2f",
                width, height, FaceRegionTracker.detectionSize,
                times.reduce(0, +) / Double(times.count), times[Int(Double(times.count) * 0.95)]
            ))
        }
    }

    /// Thirty frames a second for eight seconds of the heaviest case, with
    /// person segmentation and face detection running on their own queues the
    /// way the recorder runs them. A frame that takes longer than its slot is
    /// a frame the preview would drop.
    private static func measureSustained(context: CIContext) throws {
        let benchCase = cases[3]
        let camera = try syntheticCamera(width: benchCase.cameraWidth, height: benchCase.cameraHeight, context: context)
        let screen = try syntheticScreen(context: context)
        let mask = try personMask()
        let output = try pixelBuffer(width: benchCase.canvasWidth, height: benchCase.canvasHeight)
        let tracker = FaceRegionTracker(context: context)
        let segmentationQueue = DispatchQueue(label: "oneact.bench.segmentation")
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let segmenting = BusyFlag()

        for touchUp in [false, true] {
            let settings: TouchUpSettings? = touchUp ? TouchUpSettings(enabled: true, light: 1, warmth: 0.5, smooth: 1) : nil
            var late = 0
            var times: [Double] = []
            let frames = 240
            let start = CACurrentMediaTime()
            for frame in 0..<frames {
                let slot = start + Double(frame) / 30
                let wait = slot - CACurrentMediaTime()
                if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
                if segmenting.claim() {
                    segmentationQueue.async {
                        try? VNImageRequestHandler(cvPixelBuffer: camera, options: [:]).perform([segmentation])
                        segmenting.release()
                    }
                }
                touch(camera, frame: frame)
                touch(screen, frame: frame)
                if touchUp { tracker.request(for: camera) }
                let frameStart = CACurrentMediaTime()
                let image = compose(benchCase, camera: camera, screen: screen, mask: mask, settings: settings)
                VideoEncoding.render(image, to: output, using: context)
                CVPixelBufferLockBaseAddress(output, .readOnly)
                CVPixelBufferUnlockBaseAddress(output, .readOnly)
                let elapsed = (CACurrentMediaTime() - frameStart) * 1_000
                times.append(elapsed)
                if elapsed > 1_000.0 / 30 { late += 1 }
            }
            let seconds = CACurrentMediaTime() - start
            times.sort()
            print(String(
                format: "TOUCH_UP_BENCH sustained case=\"%@\" touch_up=%@ frames=%d fps=%.1f mean_ms=%.2f p95_ms=%.2f max_ms=%.2f late_frames=%d",
                benchCase.name, touchUp ? "on" : "off", frames, Double(frames) / seconds,
                times.reduce(0, +) / Double(times.count), times[Int(Double(times.count) * 0.95)],
                times.last ?? 0, late
            ))
        }
    }

    /// Writes one pixel, so the buffer counts as a new frame. A buffer that
    /// never changes would let Core Image serve the blurs from its cache and
    /// make every frame after the first look free.
    private static func touch(_ buffer: CVPixelBuffer, frame: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            base.assumingMemoryBound(to: UInt8.self)[frame % 4_096] = UInt8(truncatingIfNeeded: frame)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
    }

    /// Skip-if-busy, as the recorder does it for segmentation.
    private final class BusyFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var busy = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !busy else { return false }
            busy = true
            return true
        }

        func release() {
            lock.lock()
            busy = false
            lock.unlock()
        }
    }

    // MARK: - Still

    static func still(inputPath: String, outputPath: String) -> Int32 {
        guard let device = MTLCreateSystemDefaultDevice(), TouchUp.isAvailable,
              let source = CIImage(contentsOf: URL(fileURLWithPath: inputPath)) else {
            fputs("TOUCH_UP_STILL_FAILED could not read \(inputPath) or compile kernels\n", stderr)
            return 1
        }
        let context = CIContext(mtlDevice: device)
        let image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        let width = Int(image.extent.width), height = Int(image.extent.height)
        do {
            let buffer = try pixelBuffer(width: width, height: height)
            context.render(image, to: buffer)
            guard let box = FaceRegionTracker(context: context).detectSynchronously(in: buffer) else {
                print("TOUCH_UP_STILL face=none · smoothing needs a face; light and warmth only")
                return write(image, settings: stillSettings(), face: nil, to: outputPath, context: context)
            }
            print("TOUCH_UP_STILL face=\(box)")
            return write(image, settings: stillSettings(), face: FaceRegion(box: box, presence: 1), to: outputPath, context: context)
        } catch {
            fputs("TOUCH_UP_STILL_FAILED \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func stillSettings() -> TouchUpSettings {
        if CommandLine.arguments.contains("--max") {
            return TouchUpSettings(enabled: true, light: 1, warmth: 1, smooth: 1)
        }
        var settings = TouchUpSettings.defaults
        settings.enabled = true
        return settings
    }

    private static func write(_ image: CIImage, settings: TouchUpSettings, face: FaceRegion?, to path: String, context: CIContext) -> Int32 {
        let touched = TouchUp.apply(settings, to: image, face: face)
        let width = image.extent.width
        let sideBySide = touched.transformed(by: CGAffineTransform(translationX: width, y: 0)).composited(over: image)
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              (try? context.writePNGRepresentation(of: sideBySide, to: URL(fileURLWithPath: path), format: .RGBA8, colorSpace: srgb)) != nil else {
            fputs("TOUCH_UP_STILL_FAILED could not write \(path)\n", stderr)
            return 1
        }
        print("TOUCH_UP_STILL wrote \(path) settings=\(settings)")
        return 0
    }
}
