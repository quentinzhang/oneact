import AVFoundation
import CoreImage
import CoreVideo

enum VideoRecordingFormat: String, CaseIterable {
    case h264
    case proRes422

    static func stored(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .h264
    }

    var label: String {
        switch self {
        case .h264: "H.264"
        case .proRes422: "ProRes 422"
        }
    }

    var detail: String {
        switch self {
        case .h264: "Smaller files · easy to share"
        case .proRes422: "High quality · much larger files"
        }
    }

    var codec: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .proRes422: .proRes422
        }
    }
}

/// How many bits a take spends on each second of canvas.
///
/// Split out from the recorder because a single number here decides whether the
/// text in a screen recording stays readable, and because getting it wrong is
/// invisible until someone watches the file. On its own it can be exercised
/// without a camera.
///
/// The rate follows the canvas's pixel throughput rather than one of its edges.
/// Keying off width alone paid a 9:16 canvas a third less than its 16:9 twin
/// even though rotating a canvas moves no pixels, and it saturated at 1920 wide,
/// so every canvas past that point — 1440p, and anything larger — shared one
/// rate no matter how many more pixels it carried.
enum VideoEncoding {
    /// The capture stream, the writer's rate hint, and the bit rate all have to
    /// agree on the frame rate, so they all read it from here.
    static let frameRate = 30

    static let colorAttachments: [String: Any] = [
        kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_ITU_R_709_2,
        kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2
    ]

    // Derive the RGB rendering space from the same video tags the decoder
    // uses. Core Graphics' named itur_709 ICC profile is not equivalent to
    // Core Video's HDTV interpretation on macOS: rendering with the former
    // but tagging the latter lifts midtones after an encode/decode round trip.
    static let colorSpace = CVImageBufferCreateColorSpaceFromAttachments(
        colorAttachments as CFDictionary
    )!.takeRetainedValue()

    static var colorProperties: [String: Any] {
        [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
    }

    static func writerSettings(width: Int, height: Int, format: VideoRecordingFormat = .h264) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: format.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: colorProperties
        ]
        // ProRes uses its own profile-driven rate. H.264's bitrate and profile
        // keys must not leak into its compression settings.
        if format == .h264 {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitRate(width: width, height: height),
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        }
        return settings
    }

    /// Convert camera/screen colors to the SDR space advertised by the writer,
    /// and describe that same space on the uncompressed buffers.
    static func render(_ image: CIImage, to buffer: CVPixelBuffer, using context: CIContext) {
        context.render(image, to: buffer, bounds: CGRect(
            x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)
        ), colorSpace: colorSpace)
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        CVBufferSetAttachments(buffer, colorAttachments as CFDictionary, .shouldPropagate)
    }

    /// Screen recordings are dense in hard edges — text, code, window chrome —
    /// which cost far more bits than the smooth gradients of camera footage and
    /// are exactly what the viewer is trying to read. Starved of bits, H.264
    /// rings around those edges and blurs the one thing the recording is for.
    /// This sits a little above the rate YouTube asks for at each rung of its
    /// ladder to leave them room.
    private static let bitsPerPixel = 0.15

    static func bitRate(width: Int, height: Int, frameRate: Int = frameRate) -> Int {
        let pixelsPerSecond = Double(width) * Double(height) * Double(frameRate)
        return Int((pixelsPerSecond * bitsPerPixel).rounded())
    }
}
