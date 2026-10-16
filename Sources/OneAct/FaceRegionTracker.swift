import CoreImage
import CoreVideo
import QuartzCore
import Vision

/// Smooths the face box over time, the way `PersonBoxTracker` smooths the
/// person's: a deadband drops detector jitter outright and the rest is eased
/// in. It follows faster than the cutout framing does, because a smoothing
/// mask that trails a turning head would leave half the face untouched.
///
/// Unlike the person's box, a lost face is not held forever. "No face" has to
/// end in "no smoothing", so after a few misses presence fades out and the box
/// is dropped; a newly found face fades in the same way. Either way the effect
/// never switches on or off between two frames of a recording.
struct FaceBoxSmoother {
    /// Normalized to the camera frame, lower-left origin.
    private(set) var box: CGRect?
    private(set) var presence: CGFloat = 0
    private var misses = 0

    private let easing: CGFloat = 0.45
    private let deadband: CGFloat = 0.004
    private let fadeStep: CGFloat = 0.2
    /// Detections in a row without a face before the fade begins: a blink, a
    /// hand passing or a quick turn should not flicker the smoothing.
    private let missesBeforeFade = 4

    var region: FaceRegion? {
        guard let box, presence > 0 else { return nil }
        return FaceRegion(box: box, presence: presence)
    }

    mutating func update(with measurement: CGRect?) {
        guard let measurement else {
            misses += 1
            if misses >= missesBeforeFade {
                presence = max(0, presence - fadeStep)
                if presence == 0 { box = nil }
            }
            return
        }
        misses = 0
        presence = min(1, presence + fadeStep)
        guard let current = box else {
            box = measurement
            return
        }
        box = CGRect(
            x: eased(current.minX, toward: measurement.minX),
            y: eased(current.minY, toward: measurement.minY),
            width: eased(current.width, toward: measurement.width),
            height: eased(current.height, toward: measurement.height)
        )
    }

    mutating func reset() {
        box = nil
        presence = 0
        misses = 0
    }

    private func eased(_ current: CGFloat, toward target: CGFloat) -> CGFloat {
        abs(target - current) < deadband ? current : current + (target - current) * easing
    }
}

/// Finds the main face in the camera frame for skin smoothing.
///
/// Built like person segmentation: Vision runs on its own queue, a frame that
/// arrives while the previous one is still being looked at is skipped rather
/// than queued, and the capture and compositing paths only ever read the last
/// smoothed result. Detection works on a small copy of the frame — a face
/// that fills a fifth of the picture is still a hundred pixels wide at 640 —
/// and at most fifteen times a second, which the easing hides completely.
final class FaceRegionTracker: @unchecked Sendable {
    /// Longest side of the copy handed to Vision.
    static let detectionSize = 640
    private static let minimumInterval: CFTimeInterval = 1.0 / 15.0

    private let queue = DispatchQueue(label: "oneact.face", qos: .userInitiated)
    private let lock = NSLock()
    private let context: CIContext
    private var smoother = FaceBoxSmoother()
    private var inFlight = false
    private var lastRequest: CFTimeInterval = 0
    /// Bumped by `reset`, so a detection that was already running when the
    /// tracker was reset cannot write its stale box back afterwards.
    private var generation = 0
    private var pool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int) = (0, 0)
    private let faceRequest = VNDetectFaceRectanglesRequest()

    /// What one pass of the detector found. A pass that could not run at all
    /// is nil instead, which says nothing about whether a face is there.
    private enum Detection {
        case face(CGRect)
        case noFace

        var box: CGRect? {
            if case .face(let box) = self { return box }
            return nil
        }
    }

    init(context: CIContext) {
        self.context = context
    }

    var current: FaceRegion? {
        lock.lock()
        defer { lock.unlock() }
        return smoother.region
    }

    func reset() {
        lock.lock()
        smoother.reset()
        generation += 1
        lock.unlock()
    }

    /// One detection on the face queue, waited for, without touching the
    /// smoothed state. For `--touch-up-bench` and `--touch-up-still`.
    func detectSynchronously(in buffer: CVPixelBuffer) -> CGRect? {
        queue.sync { detect(in: buffer)?.box }
    }

    func request(for buffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        lock.lock()
        let busy = inFlight || now - lastRequest < Self.minimumInterval
        if !busy {
            inFlight = true
            lastRequest = now
        }
        let requestGeneration = generation
        lock.unlock()
        guard !busy else { return }

        queue.async { [weak self] in
            guard let self else { return }
            // Only a completed pass counts as a miss.
            let outcome = self.detect(in: buffer)
            self.lock.lock()
            if let outcome, requestGeneration == self.generation {
                self.smoother.update(with: outcome.box)
            }
            self.inFlight = false
            self.lock.unlock()
        }
    }

    /// Runs on the face queue. The largest face wins: the person talking to
    /// the camera is nearly always the one closest to it.
    private func detect(in buffer: CVPixelBuffer) -> Detection? {
        guard let small = downscaled(buffer) else { return nil }
        let handler = VNImageRequestHandler(cvPixelBuffer: small, orientation: .up, options: [:])
        do {
            try handler.perform([faceRequest])
        } catch {
            return nil
        }
        let faces = (faceRequest.results ?? []).filter { $0.confidence >= 0.5 }
        guard let largest = faces.max(by: { area($0.boundingBox) < area($1.boundingBox) }) else {
            return .noFace
        }
        return .face(largest.boundingBox)
    }

    private func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    /// A copy of the frame no longer than `detectionSize` on its long side.
    /// The aspect ratio is kept, so Vision's normalized box is already in the
    /// full frame's coordinates.
    private func downscaled(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, CGFloat(Self.detectionSize) / CGFloat(max(width, height)))
        let targetWidth = max(2, Int((CGFloat(width) * scale).rounded()))
        let targetHeight = max(2, Int((CGFloat(height) * scale).rounded()))
        if pool == nil || poolSize != (targetWidth, targetHeight) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: targetWidth,
                kCVPixelBufferHeightKey as String: targetHeight,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            poolSize = (targetWidth, targetHeight)
        }
        var small: CVPixelBuffer?
        guard let pool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &small) == kCVReturnSuccess,
              let small else { return nil }
        let image = CIImage(cvPixelBuffer: buffer).transformed(by: CGAffineTransform(
            scaleX: CGFloat(targetWidth) / CGFloat(width),
            y: CGFloat(targetHeight) / CGFloat(height)
        ))
        context.render(image, to: small)
        return small
    }
}
