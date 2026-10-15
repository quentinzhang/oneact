import AVFoundation
import CoreMedia

/// One camera format, reduced to what the choice actually turns on.
struct CameraFormatCandidate: Equatable {
    let width: Int
    let height: Int
    let maximumFrameRate: Double
}

/// Which of the camera's formats feeds the canvas.
///
/// The screen input has had this since `ScreenStreamGeometry`: capture at the
/// source's own pixel resolution rather than whatever a default hands over. The
/// camera never got the same treatment, so it ran on the session's default
/// preset — which picks a landscape format and knows nothing about the canvas
/// it is about to be cropped into.
///
/// That is what made the High resolution look worse than Compact. A 9:16 canvas
/// crops a 1920 × 1080 frame down to 607 × 1080 and then blows the remainder up
/// 2.4×, while the same camera offers a native 1080 × 1920 format that survives
/// the crop whole. Turning the quality control up moved the picture backwards.
enum CameraFormatSelection {
    /// Pixels that survive the crop onto the canvas — the only number that
    /// decides how much real detail reaches the encoder.
    ///
    /// Mirrors the crop `FrameCompositor.aspectFill` performs: whichever axis
    /// overhangs the canvas ratio is the one cut away, and what is left is then
    /// scaled to the canvas. A format is worth what survives that cut, not what
    /// its dimensions say on their own.
    static func croppedPixelCount(
        of candidate: CameraFormatCandidate,
        canvasWidth: Int,
        canvasHeight: Int
    ) -> Double {
        let width = Double(candidate.width)
        let height = Double(candidate.height)
        guard width > 0, height > 0, canvasWidth > 0, canvasHeight > 0 else { return 0 }

        let canvasAspect = Double(canvasWidth) / Double(canvasHeight)
        if width / height > canvasAspect {
            // Wider than the canvas: the full height survives, width is cut.
            return (height * canvasAspect) * height
        }
        // Taller than the canvas, or an exact match: the full width survives.
        return width * (width / canvasAspect)
    }

    /// Index of the format to run the camera at, or nil when there is nothing
    /// to choose from.
    static func bestIndex(
        among candidates: [CameraFormatCandidate],
        canvasWidth: Int,
        canvasHeight: Int,
        minimumFrameRate: Double = Double(VideoEncoding.frameRate)
    ) -> Int? {
        guard !candidates.isEmpty else { return nil }

        // Falling short of the recording's frame rate is a last resort, not a
        // disqualification: a camera that tops out below it should still record
        // at whatever rate it has, rather than leave the session unconfigured.
        let indices = Array(candidates.indices)
        let fastEnough = indices.filter { candidates[$0].maximumFrameRate >= minimumFrameRate }
        let pool = fastEnough.isEmpty ? indices : fastEnough

        return pool.min { lhs, rhs in
            let lhsCropped = croppedPixelCount(
                of: candidates[lhs],
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight
            )
            let rhsCropped = croppedPixelCount(
                of: candidates[rhs],
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight
            )
            if lhsCropped != rhsCropped { return lhsCropped > rhsCropped }
            // Same detail delivered: take the format that reads fewer pixels to
            // deliver it, so the cropped-away area is not carried every frame.
            let lhsTotal = candidates[lhs].width * candidates[lhs].height
            let rhsTotal = candidates[rhs].width * candidates[rhs].height
            if lhsTotal != rhsTotal { return lhsTotal < rhsTotal }
            return lhs < rhs
        }
    }
}

extension CameraFormatCandidate {
    init(_ format: AVCaptureDevice.Format) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        self.init(
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            maximumFrameRate: format.videoSupportedFrameRateRanges
                .map(\.maxFrameRate)
                .max() ?? 0
        )
    }
}

extension CameraFormatSelection {
    /// Points the device at the format that best fills the canvas and pins it
    /// to the pipeline's frame rate.
    ///
    /// macOS has no `.inputPriority` preset. Apply after the session graph has
    /// committed and started, outside begin/commitConfiguration: on the tested
    /// Mac, committing `.high` reset a portrait choice back to landscape.
    /// The recorder serializes this with capture and only changes it while idle.
    @discardableResult
    static func apply(
        canvasWidth: Int,
        canvasHeight: Int,
        to device: AVCaptureDevice
    ) -> CameraFormatCandidate? {
        let formats = device.formats
        guard let index = bestIndex(
            among: formats.map(CameraFormatCandidate.init),
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight
        ) else { return nil }

        let format = formats[index]
        let frameRate = Double(VideoEncoding.frameRate)
        let holdsFrameRate = format.videoSupportedFrameRateRanges.contains(
            where: { $0.minFrameRate <= frameRate && frameRate <= $0.maxFrameRate }
        )
        let cappedDuration = CMTime(value: 1, timescale: CMTimeScale(VideoEncoding.frameRate))

        // Already there: return without taking the lock. Only the canvas ratio
        // moves the answer, so every resolution click arrives here asking for
        // the format the camera is on — and reconfiguring the session to land
        // on the same format hitches the preview for nothing.
        if device.activeFormat == format,
           !holdsFrameRate || device.activeVideoMinFrameDuration == cappedDuration {
            return CameraFormatCandidate(format)
        }

        do {
            try device.lockForConfiguration()
        } catch {
            return nil
        }
        defer { device.unlockForConfiguration() }

        if device.activeFormat != format {
            device.activeFormat = format
        }
        // Choosing a format resets the frame duration to that format's default,
        // so the cap goes on afterwards. Only the ceiling is set: holding the
        // floor at the same rate would stop the camera lengthening its exposure
        // in a dim room, which costs more than the dropped frames it saves.
        if holdsFrameRate {
            device.activeVideoMinFrameDuration = cappedDuration
        }
        return CameraFormatCandidate(format)
    }
}
