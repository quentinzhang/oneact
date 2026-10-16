import CoreImage
import CoreVideo
import Foundation

/// The camera's look, as the user set it in the Touch-up popover.
///
/// OneAct has no editing step: the preview is the finished video, so whatever
/// someone wants to fix about how they look has to happen live. The promise is
/// "record yourself well", not "become someone else" — light, colour and skin
/// texture only, every one of them capped well short of a filter look, and no
/// reshaping of the face at all.
struct TouchUpSettings: Equatable {
    var enabled: Bool
    /// 0…1. A fill light: lifts shadows and midtones, leaves white alone.
    var light: Double
    /// −1…1. Cooler to warmer, centred on the camera's own white balance.
    var warmth: Double
    /// 0…1. Skin smoothing inside the detected face, never outside it.
    var smooth: Double

    static let off = TouchUpSettings(enabled: false, light: 0, warmth: 0, smooth: 0)
    /// Where the sliders start, and where Reset puts them back: gentle enough
    /// that switching it on reads as "better light", not as an effect.
    static let defaults = TouchUpSettings(enabled: false, light: 0.35, warmth: 0.2, smooth: 0.4)

    /// Below this a slider counts as zero, so a slider dragged back to its end
    /// stop really does switch its filter off instead of running it at 0.0003.
    static let threshold = 0.005

    var lightAmount: Double { enabled && light > Self.threshold ? min(light, 1) : 0 }
    var warmthAmount: Double { enabled && abs(warmth) > Self.threshold ? max(-1, min(warmth, 1)) : 0 }
    var smoothAmount: Double { enabled && smooth > Self.threshold ? min(smooth, 1) : 0 }

    /// Off, or on with every slider at zero: either way the camera frame goes
    /// through untouched — the exact image the compositor received.
    var isActive: Bool { lightAmount > 0 || warmthAmount != 0 || smoothAmount > 0 }

    /// Face detection only runs while there is smoothing to aim.
    var needsFaceRegion: Bool { smoothAmount > 0 }

    private enum Key {
        static let enabled = "touchUp.enabled"
        static let light = "touchUp.light"
        static let warmth = "touchUp.warmth"
        static let smooth = "touchUp.smooth"
    }

    static func stored(in defaults: UserDefaults = .standard) -> TouchUpSettings {
        func value(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            guard defaults.object(forKey: key) != nil else { return fallback }
            return max(range.lowerBound, min(defaults.double(forKey: key), range.upperBound))
        }
        let base = Self.defaults
        return TouchUpSettings(
            enabled: defaults.bool(forKey: Key.enabled),
            light: value(Key.light, base.light, 0...1),
            warmth: value(Key.warmth, base.warmth, -1...1),
            smooth: value(Key.smooth, base.smooth, 0...1)
        )
    }

    func store(in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Key.enabled)
        defaults.set(light, forKey: Key.light)
        defaults.set(warmth, forKey: Key.warmth)
        defaults.set(smooth, forKey: Key.smooth)
    }
}

/// Where the face is in the camera frame, and how sure the tracker is that it
/// is still there. Presence fades smoothing in and out over a few detections,
/// so a face found or lost never switches the effect on or off in one frame.
struct FaceRegion: Equatable {
    /// Normalized to the camera frame, lower-left origin, like Vision reports it.
    var box: CGRect
    /// 0…1.
    var presence: CGFloat
}

/// The touch-up filters themselves. Pure functions of an image, the settings
/// and a face region, so the self-test can drive them without a camera.
enum TouchUp {
    /// Fill light at full slider: the largest lift anywhere on the curve, in
    /// display-referred (sRGB-encoded) units. 0.08 is about 20 of 255 levels in
    /// the shadows; white and black do not move at all.
    static let maximumLift = 0.08
    /// Linear-light channel gains at full warmth. About +4 red and −7 blue
    /// levels on a mid grey: a warmer room, not a colour filter.
    static let maximumRedGain = 0.065
    static let maximumBlueGain = 0.11
    /// How much of the smoothed skin replaces the original at full slider.
    /// The rest of the original texture always stays in, so even the maximum
    /// keeps pores and stubble rather than turning skin into plastic.
    static let maximumSmoothing = 0.7

    /// Whether the kernels compiled. They need a Metal device that supports
    /// dynamic libraries, which every Apple Silicon Mac does; anywhere else
    /// touch-up quietly passes frames through and the popover says so.
    ///
    /// The first call compiles the Metal source, which takes about half a
    /// second; the app makes it from a background queue at launch so the first
    /// frame with touch-up on does not stall the capture queue.
    static var isAvailable: Bool { Kernels.shared != nil }

    /// The camera frame with touch-up applied, or `image` itself — the same
    /// object, not a copy — when there is nothing to apply. Alpha and extent
    /// are preserved, so the result drops into every camera layout, cutout
    /// included, exactly where the untouched frame would have gone.
    static func apply(_ settings: TouchUpSettings, to image: CIImage, face: FaceRegion?) -> CIImage {
        guard settings.isActive, let kernels = Kernels.shared else { return image }
        var result = image
        if settings.smoothAmount > 0, let face, face.presence > 0 {
            result = smoothed(result, amount: settings.smoothAmount, face: face, kernels: kernels)
        }
        if settings.lightAmount > 0 || settings.warmthAmount != 0 {
            let warmth = settings.warmthAmount
            let gains = CIVector(
                x: 1 + maximumRedGain * warmth,
                y: 1,
                z: 1 - maximumBlueGain * warmth
            )
            // The curve is lift·p·(1−p)², which peaks at p = 1/3 with a value of
            // 4/27 of `lift`; scale it so `maximumLift` is the true peak.
            let lift = settings.lightAmount * maximumLift * 27 / 4
            result = kernels.tone.apply(
                extent: result.extent,
                arguments: [result, lift, gains]
            ) ?? result
        }
        return result
    }

    /// The face ellipse in image pixels: centre, semi-axes. Vision's box runs
    /// from about the brows to the chin, so the ellipse is raised and taller
    /// than the box to take in the forehead.
    static func faceEllipse(for box: CGRect, in extent: CGRect) -> (center: CGPoint, radii: CGSize) {
        let width = box.width * extent.width
        let height = box.height * extent.height
        return (
            CGPoint(
                x: extent.minX + box.midX * extent.width,
                y: extent.minY + box.midY * extent.height + height * 0.12
            ),
            CGSize(width: width * 0.62, height: height * 0.78)
        )
    }

    /// Self-guided edge-preserving smoothing, the classic guided filter in one
    /// pass: where the local variance is small next to `epsilon` (skin texture,
    /// blemishes, sensor noise) a pixel moves toward its local mean; where it
    /// is large (eyes, brows, lips, hair against skin) it stays put. The
    /// result is mixed back with the original by the face mask, a skin-tone
    /// mask, the slider and the tracker's presence. All of it is computed only
    /// over the face's bounding box; everywhere else the frame is not read twice.
    private static func smoothed(_ image: CIImage, amount: Double, face: FaceRegion, kernels: Kernels) -> CIImage {
        let extent = image.extent
        let ellipse = faceEllipse(for: face.box, in: extent)
        guard ellipse.radii.width >= 8, ellipse.radii.height >= 8 else { return image }
        let region = CGRect(
            x: ellipse.center.x - ellipse.radii.width,
            y: ellipse.center.y - ellipse.radii.height,
            width: ellipse.radii.width * 2,
            height: ellipse.radii.height * 2
        ).integral.intersection(extent)
        guard !region.isNull, region.width >= 4, region.height >= 4 else { return image }

        // Blemishes and pores scale with the face, not with the sensor, so the
        // neighbourhood does too: about 2.5% of the face width.
        let faceWidth = face.box.width * extent.width
        let sigma = max(2, min(faceWidth * 0.025, 16))
        let margin = ceil(sigma * 3)
        let source = image.cropped(to: region.insetBy(dx: -margin, dy: -margin).intersection(extent))

        guard let encoded = kernels.encode.apply(extent: source.extent, arguments: [source]) else { return image }
        let mean = encoded.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
            .cropped(to: source.extent)
        guard let deviation = kernels.deviation.apply(
            extent: source.extent,
            arguments: [encoded, mean]
        ) else { return image }
        let variance = deviation.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
            .cropped(to: source.extent)

        // The edge threshold rises with the slider: a light setting only evens
        // out noise, a strong one also softens blemishes. Even at the top it is
        // a local standard deviation of about 18/255, so an eye, a brow or a
        // lip line, far above that, keeps nearly all of its contrast.
        // Strength follows the square root of the slider, so the first half of
        // its travel is where most of the visible change happens and the
        // default already reads as smoother skin; the cap stays the same.
        let edge = 0.03 + 0.04 * amount
        let strength = amount.squareRoot() * maximumSmoothing * Double(face.presence)
        guard let smoothedRegion = kernels.smooth.apply(
            extent: region,
            arguments: [
                image, encoded, mean, variance,
                CIVector(
                    x: ellipse.center.x,
                    y: ellipse.center.y,
                    z: 1 / ellipse.radii.width,
                    w: 1 / ellipse.radii.height
                ),
                strength,
                edge * edge
            ]
        ) else { return image }
        return smoothedRegion.composited(over: image).cropped(to: extent)
    }

    /// Runtime-compiled Metal Core Image kernels. Built-in filters cannot
    /// express the guided filter's per-pixel division or the skin-tone test
    /// without a dozen intermediate images; one small kernel each can.
    private struct Kernels: @unchecked Sendable {
        let tone: CIColorKernel
        let encode: CIColorKernel
        let deviation: CIColorKernel
        let smooth: CIColorKernel

        static let shared: Kernels? = {
            guard let kernels = try? CIKernel.kernels(withMetalString: source) else { return nil }
            func named(_ name: String) -> CIColorKernel? {
                kernels.first { $0.name == name } as? CIColorKernel
            }
            guard let tone = named("touchUpTone"),
                  let encode = named("touchUpEncode"),
                  let deviation = named("touchUpDeviation"),
                  let smooth = named("touchUpSmooth") else { return nil }
            return Kernels(tone: tone, encode: encode, deviation: deviation, smooth: smooth)
        }()
    }

    // Core Image's working space is linear light. White balance belongs
    // there; the fill-light curve, the texture threshold and the skin test are
    // about how things look, so they run on sRGB-encoded values instead.
    private static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    static inline float3 touchUpToDisplay(float3 c) {
        float3 a = abs(c);
        float3 curve = 1.055 * pow(a, 1.0 / 2.4) - 0.055;
        return sign(c) * select(curve, a * 12.92, a <= 0.0031308);
    }

    static inline float3 touchUpToLinear(float3 c) {
        float3 a = abs(c);
        float3 curve = pow((a + 0.055) / 1.055, 2.4);
        return sign(c) * select(curve, a / 12.92, a <= 0.04045);
    }

    extern "C" {

    // Warmth as linear-light channel gains, then a fill light: p + lift·p(1−p)²
    // on each encoded channel. The bump is zero at black and at white and the
    // curve stays monotonic for any lift below 3, so nothing clips that did
    // not clip already and the tonal order of the picture never changes.
    [[stitchable]] float4 touchUpTone(coreimage::sample_t s, float lift, float3 gains) {
        if (s.a <= 0.0) { return s; }
        float3 c = (s.rgb / s.a) * gains;
        if (lift > 0.0) {
            float3 p = touchUpToDisplay(c);
            float3 q = clamp(p, 0.0, 1.0);
            p += lift * q * (1.0 - q) * (1.0 - q);
            c = touchUpToLinear(p);
        }
        return float4(c * s.a, s.a);
    }

    [[stitchable]] float4 touchUpEncode(coreimage::sample_t s) {
        if (s.a <= 0.0) { return float4(0.0); }
        return float4(touchUpToDisplay(s.rgb / s.a), 1.0);
    }

    [[stitchable]] float4 touchUpDeviation(coreimage::sample_t p, coreimage::sample_t m) {
        float3 d = p.rgb - m.rgb;
        return float4(d * d, 1.0);
    }

    // original: linear frame; p: encoded frame; m, v: local mean and variance
    // of p. ellipse: centre xy and reciprocal semi-axes zw, in pixels.
    [[stitchable]] float4 touchUpSmooth(coreimage::sample_t original,
                                        coreimage::sample_t p,
                                        coreimage::sample_t m,
                                        coreimage::sample_t v,
                                        float4 ellipse,
                                        float strength,
                                        float epsilon,
                                        coreimage::destination dest) {
        float r = length((dest.coord() - ellipse.xy) * ellipse.zw);
        float face = 1.0 - smoothstep(0.6, 1.0, r);

        // Skin likelihood from the local mean, so a red blemish still counts
        // as the skin it sits on. A soft ellipse around the skin cluster in
        // CbCr — the same chroma across light and dark complexions — gated
        // off in deep shadow. Lips sit at its edge and eye whites, irises,
        // brows, hair and most backgrounds fall outside it.
        float y = dot(m.rgb, float3(0.299, 0.587, 0.114));
        float cb = dot(m.rgb, float3(-0.168736, -0.331264, 0.5));
        float cr = dot(m.rgb, float3(0.5, -0.418688, -0.081312));
        float chroma = length(float2((cb + 0.09) / 0.085, (cr - 0.10) / 0.07));
        float skin = (1.0 - smoothstep(0.9, 1.5, chroma)) * smoothstep(0.05, 0.15, y);

        float weight = strength * face * skin;
        if (weight <= 0.0) { return original; }

        // Guided filter with the image as its own guide: a → 1 on edges,
        // a → 0 on flat texture. The largest channel variance decides, so a
        // chroma-only edge such as a lip line is kept as well as a luma edge.
        float variance = max(v.r, max(v.g, v.b));
        float a = variance / (variance + epsilon);
        float3 base = mix(m.rgb, p.rgb, a);
        float3 result = mix(p.rgb, base, weight);
        return float4(touchUpToLinear(result) * original.a, original.a);
    }

    }
    """
}

/// Touch-up as the recorder sees it: the current settings, the face tracker
/// that aims the smoothing, and the one call that turns a camera frame into a
/// touched-up one. Settings arrive from the main thread; frames are processed
/// on the capture queue.
final class TouchUpStage: @unchecked Sendable {
    let faceTracker: FaceRegionTracker
    private let lock = NSLock()
    private var settings = TouchUpSettings.off

    init(context: CIContext) {
        faceTracker = FaceRegionTracker(context: context)
    }

    func update(_ newSettings: TouchUpSettings) {
        lock.lock()
        settings = newSettings
        lock.unlock()
        // A face box from before smoothing was switched off is stale by the
        // time it is switched back on; find the face again from scratch.
        if !newSettings.needsFaceRegion { faceTracker.reset() }
    }

    var current: TouchUpSettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    var isActive: Bool { current.isActive && TouchUp.isAvailable }

    /// Hands a camera frame to face detection when smoothing needs a face.
    /// Detection runs on its own queue and skips frames while busy.
    func observe(_ buffer: CVPixelBuffer) {
        guard current.needsFaceRegion, TouchUp.isAvailable else { return }
        faceTracker.request(for: buffer)
    }

    func apply(to image: CIImage) -> CIImage {
        let settings = current
        guard settings.isActive else { return image }
        return TouchUp.apply(
            settings,
            to: image,
            face: settings.needsFaceRegion ? faceTracker.current : nil
        )
    }
}
