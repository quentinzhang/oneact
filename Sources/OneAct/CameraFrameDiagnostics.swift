import AVFoundation
import CoreImage
import CoreVideo

/// Opt-in, local-only evidence from the actual recorder. The source is the
/// uncompressed frame delivered by AVFoundation, including any system effects;
/// it is not sensor RAW. No frames are saved during normal recording.
final class CameraFrameDiagnostics {
    private let directory: URL
    private let queue = DispatchQueue(label: "oneact.camera-diagnostic.files")
    private let context = CIContext()
    private var firstTime: CMTime?
    private var nextSnapshot = 0
    private let snapshotTimes = [2.0, 4.0, 6.0]
    private var entries: [[String: Any]] = []
    private var failure: Error?

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Called on the capture queue only after the exact output sample was
    /// accepted by AVAssetWriter. Retaining both buffers until PNG writing
    /// completes keeps the pool from recycling their storage underneath us.
    func inspect(
        source: CMSampleBuffer,
        output: CMSampleBuffer,
        sessionStartTime: CMTime,
        device: AVCaptureDevice,
        sessionPreset: AVCaptureSession.Preset,
        videoSettings: [String: Any]
    ) {
        let pts = CMSampleBufferGetPresentationTimeStamp(output)
        if firstTime == nil { firstTime = pts }
        let elapsed = CMTimeGetSeconds(pts - firstTime!)
        guard nextSnapshot < snapshotTimes.count,
              elapsed >= snapshotTimes[nextSnapshot],
              let sourceBuffer = CMSampleBufferGetImageBuffer(source),
              let outputBuffer = CMSampleBufferGetImageBuffer(output) else { return }
        let index = nextSnapshot
        nextSnapshot += 1
        let format = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let metadata: [String: Any] = [
            "index": index,
            // Audio can start the writer before the first video callback, and
            // accepted video samples before that start are clipped by the
            // writer. Use its session origin, not the first video sample.
            "movie_time_seconds": CMTimeGetSeconds(pts - sessionStartTime),
            "clock_reference": "writer_session_start",
            "elapsed_video_seconds": elapsed,
            "writer_session_start_seconds": CMTimeGetSeconds(sessionStartTime),
            "sample_pts_seconds": CMTimeGetSeconds(pts),
            "source_width": CVPixelBufferGetWidth(sourceBuffer),
            "source_height": CVPixelBufferGetHeight(sourceBuffer),
            "source_pixel_format": CVPixelBufferGetPixelFormatType(sourceBuffer),
            "output_width": CVPixelBufferGetWidth(outputBuffer),
            "output_height": CVPixelBufferGetHeight(outputBuffer),
            "device_name": device.localizedName,
            "active_format_width": format.width,
            "active_format_height": format.height,
            "session_preset": sessionPreset.rawValue,
            "video_settings": videoSettings.mapValues { String(describing: $0) },
            "portrait_enabled": AVCaptureDevice.isPortraitEffectEnabled,
            "portrait_active": device.isPortraitEffectActive,
            "studio_light_enabled": AVCaptureDevice.isStudioLightEnabled,
            "studio_light_active": device.isStudioLightActive,
            "background_replacement_enabled": AVCaptureDevice.isBackgroundReplacementEnabled,
            "background_replacement_active": device.isBackgroundReplacementActive,
            "center_stage_enabled": AVCaptureDevice.isCenterStageEnabled,
            "center_stage_active": device.isCenterStageActive,
            "source_attachments": String(describing: CVBufferCopyAttachments(sourceBuffer, .shouldPropagate)),
            "output_attachments": String(describing: CVBufferCopyAttachments(outputBuffer, .shouldPropagate))
        ]
        queue.async { [self, sourceBuffer, outputBuffer] in
            do {
                let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
                for (stage, buffer) in [("source", sourceBuffer), ("preencode", outputBuffer)] {
                    try context.writePNGRepresentation(
                        of: CIImage(cvPixelBuffer: buffer),
                        to: directory.appendingPathComponent("frame-\(index)-\(stage).png"),
                        format: .RGBA8,
                        colorSpace: colorSpace
                    )
                }
                entries.append(metadata)
            } catch {
                failure = error
            }
        }
    }

    func finish(completion: @escaping (Result<Int, Error>) -> Void) {
        queue.async { [self] in
            do {
                if let failure { throw failure }
                guard entries.count == snapshotTimes.count else {
                    throw NSError(domain: "OneAct.CameraDiagnostic", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Expected three paired snapshots; captured \(entries.count)."
                    ])
                }
                let json = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
                try json.write(to: directory.appendingPathComponent("frames.json"), options: .atomic)
                completion(.success(entries.count))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
