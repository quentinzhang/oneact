import AVFoundation
import CoreVideo

/// Describes the delivered frame, including effects applied by macOS before
/// capture. A discovery-only device or requested format is not sufficient.
struct CameraCaptureState: Equatable {
    let width: Int
    let height: Int
    let portrait: Bool
    let studioLight: Bool
    let backgroundReplacement: Bool
    let centerStage: Bool

    init(buffer: CVPixelBuffer, device: AVCaptureDevice) {
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        portrait = device.isPortraitEffectActive
        studioLight = device.isStudioLightActive
        backgroundReplacement = device.isBackgroundReplacementActive
        centerStage = device.isCenterStageActive
    }

    var effects: [String] {
        var result: [String] = []
        if portrait { result.append("Portrait") }
        if studioLight { result.append("Light") }
        if backgroundReplacement { result.append("Background") }
        if centerStage { result.append("Center Stage") }
        return result
    }

    var effectsTitle: String {
        effects.isEmpty ? "Effects: Off" : "Effects: " + effects.joined(separator: " · ")
    }

    func requiresUpscaling(width outputWidth: Int, height outputHeight: Int, zoom: CGFloat) -> Bool {
        max(Double(outputWidth) / Double(width), Double(outputHeight) / Double(height))
            * Double(SoftwareZoom.clamp(zoom)) > 1.001
    }
}
