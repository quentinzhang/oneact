import CoreImage
import CoreVideo
import Foundation
import Metal

/// Touch-up checks for `--self-test`. Everything here runs on a Metal context,
/// like the recorder: the kernels are compiled Metal and have no software path.
enum TouchUpSelfTest {
    static func run() throws -> String {
        guard TouchUp.isAvailable, let device = MTLCreateSystemDefaultDevice() else {
            throw TouchUpSelfTestError.unavailable
        }
        let context = CIContext(mtlDevice: device)
        try verifyOffIsIdentity(context: context)
        let smoothing = try verifySmoothing(context: context)
        let tone = try verifyLightAndWarmth(context: context)
        try verifyScreenUntouched(context: context)
        try verifyFaceSmoother()
        try verifyPersistence()
        return "touch_up=[off_identity=verified \(smoothing) \(tone) screen_untouched=verified face_tracking=deadband_ease_fade settings_persist=verified]"
    }

    // MARK: - Synthetic camera frame

    /// An sRGB RGBA8 picture addressed in Core Image coordinates (lower-left
    /// origin), so positions in the checks read the same as in the filters.
    struct Picture {
        let width: Int
        let height: Int
        var bytes: [UInt8]

        init(width: Int, height: Int, fill: [UInt8]) {
            self.width = width
            self.height = height
            bytes = [UInt8](repeating: 255, count: width * height * 4)
            for index in 0..<(width * height) {
                for channel in 0..<3 { bytes[index * 4 + channel] = fill[channel] }
            }
        }

        init(width: Int, height: Int, bytes: [UInt8]) {
            self.width = width
            self.height = height
            self.bytes = bytes
        }

        func offset(_ x: Int, _ y: Int) -> Int { ((height - 1 - y) * width + x) * 4 }

        subscript(x: Int, y: Int, channel: Int) -> UInt8 {
            get { bytes[offset(x, y) + channel] }
            set { bytes[offset(x, y) + channel] = newValue }
        }

        mutating func paint(_ color: [UInt8], noise: Double = 0, random: inout SeededRandom, where inside: (Int, Int) -> Bool) {
            for y in 0..<height {
                for x in 0..<width where inside(x, y) {
                    let jitter = noise > 0 ? random.gaussian() * noise : 0
                    for channel in 0..<3 {
                        self[x, y, channel] = UInt8(max(0, min(255, (Double(color[channel]) + jitter).rounded())))
                    }
                }
            }
        }

        var image: CIImage {
            CIImage(
                bitmapData: Data(bytes),
                bytesPerRow: width * 4,
                size: CGSize(width: width, height: height),
                format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
            )
        }

        static func rendered(_ image: CIImage, width: Int, height: Int, context: CIContext) -> Picture {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            context.render(
                image,
                toBitmap: &bytes,
                rowBytes: width * 4,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
            )
            return Picture(width: width, height: height, bytes: bytes)
        }

        /// Standard deviation of one channel over a rectangle.
        func deviation(_ rect: CGRect, channel: Int = 1) -> Double {
            let values = samples(rect, channel: channel)
            let mean = values.reduce(0, +) / Double(values.count)
            return (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)).squareRoot()
        }

        func mean(_ rect: CGRect, channel: Int) -> Double {
            let values = samples(rect, channel: channel)
            return values.reduce(0, +) / Double(values.count)
        }

        func luma(_ rect: CGRect) -> Double {
            0.299 * mean(rect, channel: 0) + 0.587 * mean(rect, channel: 1) + 0.114 * mean(rect, channel: 2)
        }

        private func samples(_ rect: CGRect, channel: Int) -> [Double] {
            var values: [Double] = []
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    values.append(Double(self[x, y, channel]))
                }
            }
            return values
        }
    }

    /// Deterministic, so a failing run can be reproduced exactly.
    struct SeededRandom {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func uniform() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }

        /// Irwin–Hall approximation: plenty for sensor-like noise.
        mutating func gaussian() -> Double {
            (0..<12).reduce(0) { sum, _ in sum + uniform() } - 6
        }
    }

    /// A noisy face-like patch: skin with sensor noise and blemishes, dark
    /// eyes with bright whites, brows and lips — the hard edges that have to
    /// survive smoothing — on a noisy backdrop that has to survive untouched.
    struct SyntheticFace {
        static let width = 640
        static let height = 480
        static let center = CGPoint(x: 320, y: 230)
        static let radii = CGSize(width: 110, height: 145)
        /// Where Vision would put the box: roughly brows to chin.
        static let box = CGRect(x: 215.0 / 640, y: 90.0 / 480, width: 210.0 / 640, height: 210.0 / 480)
        static let leftCheek = CGRect(x: 258, y: 188, width: 24, height: 24)
        static let rightCheek = CGRect(x: 358, y: 188, width: 24, height: 24)
        static let leftIris = CGRect(x: 268, y: 254, width: 12, height: 12)
        static let leftEyeSkin = CGRect(x: 262, y: 230, width: 24, height: 10)
        static let leftBrow = CGRect(x: 250, y: 286, width: 50, height: 8)
        static let browSkin = CGRect(x: 250, y: 300, width: 50, height: 8)

        static func make() -> Picture {
            var random = SeededRandom(seed: 0x0ae7_2026)
            var picture = Picture(width: width, height: height, fill: [70, 95, 120])
            picture.paint([70, 95, 120], noise: 5, random: &random) { _, _ in true }
            picture.paint([205, 155, 128], noise: 7, random: &random) { x, y in
                let dx = (Double(x) - center.x) / radii.width
                let dy = (Double(y) - center.y) / radii.height
                return dx * dx + dy * dy <= 1
            }
            // Blemishes: small reddish spots a few pixels across.
            for spot in [(300, 205), (345, 215), (290, 180), (360, 175), (330, 290)] {
                picture.paint([185, 120, 105], noise: 4, random: &random) { x, y in
                    let dx = x - spot.0, dy = y - spot.1
                    return dx * dx + dy * dy <= 9
                }
            }
            for eyeX in [254, 344] {
                picture.paint([228, 222, 218], random: &random) { x, y in
                    x >= eyeX && x < eyeX + 42 && y >= 252 && y < 268
                }
                picture.paint([40, 30, 26], random: &random) { x, y in
                    x >= eyeX + 14 && x < eyeX + 26 && y >= 254 && y < 266
                }
                picture.paint([60, 42, 35], random: &random) { x, y in
                    x >= eyeX - 4 && x < eyeX + 46 && y >= 286 && y < 294
                }
            }
            picture.paint([170, 80, 88], random: &random) { x, y in
                let dx = Double(x - 320) / 34, dy = Double(y - 160) / 10
                return dx * dx + dy * dy <= 1
            }
            return picture
        }
    }

    // MARK: - Checks

    /// Off, or on with every slider at zero, has to be today's pipeline: the
    /// same image object back, and the same bytes out of the compositor.
    private static func verifyOffIsIdentity(context: CIContext) throws {
        let camera = SyntheticFace.make().image
        let face = FaceRegion(box: SyntheticFace.box, presence: 1)
        let inactive = [
            TouchUpSettings(enabled: false, light: 1, warmth: 1, smooth: 1),
            TouchUpSettings(enabled: true, light: 0, warmth: 0, smooth: 0),
            TouchUpSettings.off
        ]
        for settings in inactive {
            guard !settings.isActive, TouchUp.apply(settings, to: camera, face: face) === camera else {
                throw TouchUpSelfTestError.offNotIdentity("inactive settings returned a new image")
            }
        }
        // Smoothing alone with no face found has nothing to aim at.
        let smoothOnly = TouchUpSettings(enabled: true, light: 0, warmth: 0, smooth: 1)
        guard TouchUp.apply(smoothOnly, to: camera, face: nil) === camera,
              TouchUp.apply(smoothOnly, to: camera, face: FaceRegion(box: SyntheticFace.box, presence: 0)) === camera else {
            throw TouchUpSelfTestError.offNotIdentity("smoothing ran without a face")
        }

        let stage = TouchUpStage(context: context)
        stage.update(TouchUpSettings(enabled: false, light: 0.8, warmth: -0.5, smooth: 0.6))
        let width = 1_280, height = 720
        let plain = try renderBytes(FrameCompositor.aspectFill(camera, width: width, height: height, zoom: 1.4),
                                    width: width, height: height, context: context)
        let staged = try renderBytes(FrameCompositor.aspectFill(stage.apply(to: camera), width: width, height: height, zoom: 1.4),
                                     width: width, height: height, context: context)
        let screen = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        func composed(_ cameraImage: CIImage) -> CIImage {
            FrameCompositor.screenWithCamera(
                screen: screen, camera: cameraImage, width: width, height: height,
                cameraZoom: 1, position: .bottomRight, screenLayout: .blur, cameraFrame: .circle
            )
        }
        let plainComposite = try renderBytes(composed(camera), width: width, height: height, context: context)
        let stagedComposite = try renderBytes(composed(stage.apply(to: camera)), width: width, height: height, context: context)
        guard plain == staged, plainComposite == stagedComposite else {
            throw TouchUpSelfTestError.offNotIdentity("rendered bytes differ with touch-up off")
        }
    }

    /// With a face rect on the synthetic patch: noise inside the mask drops,
    /// everything outside the face ellipse keeps its exact bytes, and the
    /// eye and brow edges keep their contrast.
    private static func verifySmoothing(context: CIContext) throws -> String {
        let source = SyntheticFace.make()
        let width = SyntheticFace.width, height = SyntheticFace.height
        let face = FaceRegion(box: SyntheticFace.box, presence: 1)
        let original = Picture.rendered(source.image, width: width, height: height, context: context)

        func smoothed(_ amount: Double) -> Picture {
            let settings = TouchUpSettings(enabled: true, light: 0, warmth: 0, smooth: amount)
            return Picture.rendered(TouchUp.apply(settings, to: source.image, face: face),
                                    width: width, height: height, context: context)
        }
        let full = smoothed(1)
        let gentle = smoothed(TouchUpSettings.defaults.smooth)

        let cheeks = [SyntheticFace.leftCheek, SyntheticFace.rightCheek]
        let before = cheeks.map { original.deviation($0) }.reduce(0, +) / 2
        let afterFull = cheeks.map { full.deviation($0) }.reduce(0, +) / 2
        let afterGentle = cheeks.map { gentle.deviation($0) }.reduce(0, +) / 2

        // Outside the ellipse the mask is zero, and zero means the original
        // sample is returned — not a re-encoded copy one rounding step away.
        let ellipse = TouchUp.faceEllipse(
            for: SyntheticFace.box,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        var outsideChanged = 0, outsideCount = 0
        for y in 0..<height {
            for x in 0..<width {
                let dx = (Double(x) + 0.5 - ellipse.center.x) / ellipse.radii.width
                let dy = (Double(y) + 0.5 - ellipse.center.y) / ellipse.radii.height
                guard dx * dx + dy * dy > 1.0 else { continue }
                outsideCount += 1
                let offset = original.offset(x, y)
                if original.bytes[offset..<offset + 4] != full.bytes[offset..<offset + 4] { outsideChanged += 1 }
            }
        }

        // Edge contrast: iris against the skin under the eye, brow against
        // the skin above it.
        let irisContrast = { (picture: Picture) in
            picture.luma(SyntheticFace.leftEyeSkin) - picture.luma(SyntheticFace.leftIris)
        }
        let browContrast = { (picture: Picture) in
            picture.luma(SyntheticFace.browSkin) - picture.luma(SyntheticFace.leftBrow)
        }
        let irisKept = irisContrast(full) / irisContrast(original)
        let browKept = browContrast(full) / browContrast(original)

        let fullReduction = 1 - afterFull / before
        let gentleReduction = 1 - afterGentle / before
        let summary = String(
            format: "smooth_noise=%.2f→%.2f(default)→%.2f(max) outside_changed=%d/%d iris_contrast_kept=%.3f brow_contrast_kept=%.3f",
            before, afterGentle, afterFull, outsideChanged, outsideCount, irisKept, browKept
        )
        guard fullReduction >= 0.45, fullReduction <= 0.8,
              gentleReduction >= 0.2,
              gentleReduction < fullReduction,
              outsideCount > 0, outsideChanged == 0,
              irisKept >= 0.92, browKept >= 0.92 else {
            throw TouchUpSelfTestError.smoothingFailed(summary)
        }
        return summary
    }

    /// Warmth moves red up and blue down (and back for cool); light lifts
    /// shadows and midtones while white, black and the tonal order stay put.
    private static func verifyLightAndWarmth(context: CIContext) throws -> String {
        let width = 256, height = 4
        var ramp = Picture(width: width, height: height, fill: [0, 0, 0])
        for y in 0..<height {
            for x in 0..<width {
                for channel in 0..<3 { ramp[x, y, channel] = UInt8(x) }
            }
        }
        // Row 0 carries a skin tone in its first columns; rows 1… are the ramp.
        for x in 0..<16 { ramp[x, 0, 0] = 190; ramp[x, 0, 1] = 135; ramp[x, 0, 2] = 110 }

        func render(_ settings: TouchUpSettings) -> Picture {
            Picture.rendered(TouchUp.apply(settings, to: ramp.image, face: nil), width: width, height: height, context: context)
        }
        let original = Picture.rendered(ramp.image, width: width, height: height, context: context)
        let warm = render(TouchUpSettings(enabled: true, light: 0, warmth: 1, smooth: 0))
        let cool = render(TouchUpSettings(enabled: true, light: 0, warmth: -1, smooth: 0))
        let lit = render(TouchUpSettings(enabled: true, light: 1, warmth: 0, smooth: 0))

        func delta(_ picture: Picture, x: Int, y: Int = 1, channel: Int) -> Int {
            Int(picture[x, y, channel]) - Int(original[x, y, channel])
        }
        let grayWarm = (r: delta(warm, x: 128, channel: 0), g: delta(warm, x: 128, channel: 1), b: delta(warm, x: 128, channel: 2))
        let grayCool = (r: delta(cool, x: 128, channel: 0), g: delta(cool, x: 128, channel: 1), b: delta(cool, x: 128, channel: 2))
        let skinWarm = (r: delta(warm, x: 8, y: 0, channel: 0), b: delta(warm, x: 8, y: 0, channel: 2))
        let warmthOK = grayWarm.r > 0 && grayWarm.b < 0 && abs(grayWarm.g) <= 1
            && grayCool.r < 0 && grayCool.b > 0 && abs(grayCool.g) <= 1
            && skinWarm.r > 0 && skinWarm.b < 0
            // Subtle at the top of the slider: a few levels, not a tint.
            && grayWarm.r <= 6 && grayWarm.b >= -12 && grayCool.r >= -6 && grayCool.b <= 12

        let shadowLift = delta(lit, x: 40, channel: 1)
        let midLift = delta(lit, x: 128, channel: 1)
        let highlightLift = delta(lit, x: 245, channel: 1)
        var monotonic = true
        var clipped = 0
        for x in 1..<width {
            if lit[x, 1, 1] < lit[x - 1, 1, 1] { monotonic = false }
            if lit[x, 1, 1] == 255 && original[x, 1, 1] != 255 { clipped += 1 }
        }
        let lightOK = shadowLift >= 10 && shadowLift <= 24
            && midLift >= 6 && highlightLift <= 3
            && lit[0, 1, 1] <= 1 && lit[255, 1, 1] == 255
            && monotonic && clipped == 0

        let summary = "warmth_gray=+\(grayWarm.r)R/\(grayWarm.b)B cool_gray=\(grayCool.r)R/+\(grayCool.b)B light_lift=\(shadowLift)@40,\(midLift)@128,\(highlightLift)@245 clipped=\(clipped)"
        guard warmthOK, lightOK else { throw TouchUpSelfTestError.toneFailed(summary) }
        return summary
    }

    /// Touch-up is a camera-layer effect. Composited over a screen, in a frame
    /// or as a cutout, only pixels inside the camera's own footprint change.
    private static func verifyScreenUntouched(context: CIContext) throws {
        let width = 1_280, height = 720
        let camera = SyntheticFace.make().image
        let settings = TouchUpSettings(enabled: true, light: 1, warmth: 1, smooth: 1)
        let touched = TouchUp.apply(settings, to: camera, face: FaceRegion(box: SyntheticFace.box, presence: 1))
        var random = SeededRandom(seed: 7)
        var screenPicture = Picture(width: 1_920, height: 1_080, fill: [30, 30, 30])
        screenPicture.paint([30, 30, 30], noise: 40, random: &random) { _, _ in true }
        let screen = screenPicture.image

        // A person mask covering the middle of the camera frame, in the red
        // channel like Vision's.
        let mask = CIImage(color: .white)
            .cropped(to: CGRect(x: 200, y: 0, width: 240, height: 400))
            .composited(over: CIImage(color: .black).cropped(to: camera.extent))

        for style in [CameraFrameStyle.rectangle, .cutout] {
            let pipFrame = FrameCompositor.cameraOverlayFrame(
                canvasWidth: CGFloat(width), canvasHeight: CGFloat(height), style: style, position: .bottomRight
            )
            let footprint: CGRect
            func compose(_ cameraImage: CIImage) -> CIImage {
                let layer = style == .cutout ? FrameCompositor.personCutout(camera: cameraImage, mask: mask) : cameraImage
                return FrameCompositor.screenWithCamera(
                    screen: screen, camera: layer, width: width, height: height, cameraZoom: 1,
                    position: .bottomRight, screenLayout: .fill, cameraFrame: style
                )
            }
            if style == .cutout {
                footprint = FrameCompositor.cutoutPlacement(
                    cameraExtent: camera.extent, personBox: nil, region: pipFrame,
                    canvasWidth: CGFloat(width), canvasHeight: CGFloat(height)
                ).cameraRect
            } else {
                footprint = pipFrame
            }
            let plain = Picture.rendered(compose(camera), width: width, height: height, context: context)
            let adjusted = Picture.rendered(compose(touched), width: width, height: height, context: context)
            var changedInside = 0, changedOutside = 0
            let allowed = footprint.insetBy(dx: -2, dy: -2)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = plain.offset(x, y)
                    guard plain.bytes[offset..<offset + 4] != adjusted.bytes[offset..<offset + 4] else { continue }
                    if allowed.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                        changedInside += 1
                    } else {
                        changedOutside += 1
                    }
                }
            }
            guard changedOutside == 0, changedInside > 1_000 else {
                throw TouchUpSelfTestError.screenTouched("\(style.label) inside=\(changedInside) outside=\(changedOutside)")
            }
        }
    }

    /// The face box follows like the cutout's person box — jitter dropped,
    /// real movement eased in — but a face that stays lost fades out and is
    /// dropped, because no face has to end in no smoothing.
    private static func verifyFaceSmoother() throws {
        var smoother = FaceBoxSmoother()
        let start = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3)
        smoother.update(with: start)
        let first = smoother.region
        smoother.update(with: start.offsetBy(dx: 0.002, dy: -0.002))
        let jittered = smoother.box
        smoother.update(with: start.offsetBy(dx: 0.1, dy: 0))
        let moved = smoother.box?.minX ?? 0
        for _ in 0..<3 { smoother.update(with: start) }
        let presenceFull = smoother.presence
        // A blink's worth of misses changes nothing…
        for _ in 0..<3 { smoother.update(with: nil) }
        let afterBlink = smoother.region
        // …a face that stays gone fades out and is dropped.
        for _ in 0..<10 { smoother.update(with: nil) }
        let afterLoss = smoother.region
        guard let first, first.presence > 0, first.presence < 1, first.box == start,
              jittered == start,
              moved > start.minX + 0.02, moved < start.minX + 0.1,
              presenceFull == 1,
              afterBlink?.presence == 1,
              afterLoss == nil else {
            throw TouchUpSelfTestError.trackingFailed(
                "first=\(String(describing: first)) jittered=\(String(describing: jittered)) moved=\(moved) presence=\(presenceFull) blink=\(String(describing: afterBlink)) lost=\(String(describing: afterLoss))"
            )
        }
    }

    /// Settings survive a relaunch, and a stored value out of range is pulled
    /// back in rather than trusted.
    private static func verifyPersistence() throws {
        let suite = "oneact.selftest.touchup.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw TouchUpSelfTestError.persistenceFailed }
        defer { defaults.removePersistentDomain(forName: suite) }
        guard TouchUpSettings.stored(in: defaults) == .defaults else { throw TouchUpSelfTestError.persistenceFailed }
        let chosen = TouchUpSettings(enabled: true, light: 0.6, warmth: -0.3, smooth: 0.25)
        chosen.store(in: defaults)
        guard TouchUpSettings.stored(in: defaults) == chosen else { throw TouchUpSelfTestError.persistenceFailed }
        defaults.set(7.0, forKey: "touchUp.smooth")
        guard TouchUpSettings.stored(in: defaults).smooth == 1 else { throw TouchUpSelfTestError.persistenceFailed }
    }

    private static func renderBytes(_ image: CIImage, width: Int, height: Int, context: CIContext) throws -> [UInt8] {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                                  &buffer) == kCVReturnSuccess, let buffer else {
            throw TouchUpSelfTestError.unavailable
        }
        VideoEncoding.render(image, to: buffer, using: context)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw TouchUpSelfTestError.unavailable }
        return Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: bytesPerRow * height))
    }
}

private enum TouchUpSelfTestError: LocalizedError {
    case unavailable
    case offNotIdentity(String)
    case smoothingFailed(String)
    case toneFailed(String)
    case screenTouched(String)
    case trackingFailed(String)
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: "touch-up kernels did not compile on this Mac's Metal device"
        case .offNotIdentity(let detail): "touch-up off is not identical to the plain path: \(detail)"
        case .smoothingFailed(let detail): "skin smoothing missed its bounds: \(detail)"
        case .toneFailed(let detail): "light or warmth moved the wrong way or too far: \(detail)"
        case .screenTouched(let detail): "touch-up reached outside the camera layer: \(detail)"
        case .trackingFailed(let detail): "face box smoothing, deadband or fade-out misbehaved: \(detail)"
        case .persistenceFailed: "touch-up settings did not round-trip through UserDefaults"
        }
    }
}
