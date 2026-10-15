import AVFoundation
import AudioToolbox
import CoreImage
import CoreMedia
import CoreVideo

enum WriterSelfTest {
    static func run(outputPath: String, format: VideoRecordingFormat = .h264) -> Int32 {
        let url = URL(fileURLWithPath: outputPath)
        try? FileManager.default.removeItem(at: url)

        do {
            try verifySoftwareZoomCrop()
            try verifyScreenCameraComposition()
            try verifyCameraFrameStyles()
            try verifyCameraPlacement()
            try verifyScreenLayoutModes()
            try verifyTransparentSourceCorners()
            try verifyScreenStreamGeometry()
            let cameraFormatSummary = try verifyCameraFormatSelection()
            try verifyVideoBitRate()
            let colorSummary = try verifyVideoColorRoundTrip(format: format)
            try verifyCameraOutputLimit()
            try verifyLanczosUpscaling()
            let pauseSummary = try verifyPausedRecording(format: format)
            let mixSummary = try verifyAudioMixing()
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let settings = VideoEncoding.writerSettings(width: 1080, height: 1920, format: format)
            guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
                throw SelfTestError.writerStartFailed
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            // A non-realtime input expects to be pulled via
            // requestMediaDataWhenReady; pushed in a busy-wait loop like this
            // one it intermittently stops reporting ready and never recovers,
            // hanging the whole run. The recorder writes in realtime mode too.
            input.expectsMediaDataInRealTime = true
            let audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 128_000
                ]
            )
            audioInput.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: 1080,
                    kCVPixelBufferHeightKey as String: 1920,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
            )
            writer.add(input)
            guard writer.canAdd(audioInput) else { throw SelfTestError.audioWriterInputFailed }
            writer.add(audioInput)
            guard writer.startWriting() else { throw writer.error ?? SelfTestError.writerStartFailed }
            writer.startSession(atSourceTime: .zero)

            let context = CIContext()
            var audioFrame: Int64 = 0
            for frame in 0..<90 {
                try waitForInput(input, writer: writer)
                var pixelBuffer: CVPixelBuffer?
                let status = CVPixelBufferCreate(nil, 1080, 1920, kCVPixelFormatType_32BGRA,
                                                 [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                                                 &pixelBuffer)
                guard status == kCVReturnSuccess, let pixelBuffer else { throw SelfTestError.pixelBufferFailed }
                let hue = CGFloat(frame % 90) / 90.0
                let color = CIColor(red: 0.15 + hue * 0.7, green: 0.25, blue: 0.8 - hue * 0.55)
                let wideSource = CIImage(color: color).cropped(
                    to: CGRect(x: 0, y: 0, width: 1920, height: 1080)
                )
                let zoom = frame < 45 ? CGFloat(1) : CGFloat(2)
                let verticalFrame = FrameCompositor.aspectFill(
                    wideSource,
                    width: 1080,
                    height: 1920,
                    zoom: zoom
                )
                VideoEncoding.render(verticalFrame, to: pixelBuffer, using: context)
                guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)) else {
                    throw writer.error ?? SelfTestError.appendFailed
                }
                try waitForInput(audioInput, writer: writer)
                let frameCount = 1_600
                let sampleBuffer = try syntheticAudioSampleBuffer(
                    startFrame: audioFrame,
                    frameCount: frameCount,
                    sampleRate: 48_000
                )
                guard audioInput.append(sampleBuffer) else {
                    throw writer.error ?? SelfTestError.audioAppendFailed
                }
                audioFrame += Int64(frameCount)
            }
            input.markAsFinished()
            audioInput.markAsFinished()
            let group = DispatchGroup()
            group.enter()
            writer.finishWriting { group.leave() }
            group.wait()
            guard writer.status == .completed else { throw writer.error ?? SelfTestError.writerFailed }
            let decodedLuma = try decodedAverageLuma(url: url)
            guard decodedLuma > 0.05 else { throw SelfTestError.blackFrame }
            guard assetContainsAudio(url: url) else { throw SelfTestError.audioTrackMissing }
            print("SELF_TEST_OK path=\(url.path) width=1080 height=1920 frames=90 codec=\(format.rawValue) audio=aac software_zoom_crop=verified software_zoom_clamped=verified screen_camera_pip=verified camera_frames=rect_circle_cutout_hidden cutout_placement=mask_anchored_uncropped camera_placement=drag_size_pan_verified screen_layouts=fit_fill_blur canvas_backdrop=verified transparent_corners=flattened iphone_mirroring_ratio=verified camera_format=[\(cameraFormatSummary)] camera_output_limit=verified lanczos_upscale=verified color_roundtrip=\(colorSummary) pause_resume=\(pauseSummary) audio_mix=\(mixSummary) average_luma=\(decodedLuma)")
            return 0
        } catch {
            fputs("SELF_TEST_FAILED \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    /// Exercises the audio mixer with synthetic sources whose sums are known.
    ///
    /// The mixer decides every sample of the finished track, and a subtle bug
    /// — misaligned ring reads, a broken converter, a limiter that engages at
    /// the wrong level — produces a file that records fine and sounds wrong.
    /// Silence, a constant tone, and full-scale input have exactly predictable
    /// outputs, so they are what gets asserted.
    private static func verifyAudioMixing() throws -> String {
        let mixer = AudioMixer()
        var mixed: [CMSampleBuffer] = []
        mixer.onMixedBuffer = { mixed.append($0) }

        func floatSamples(_ sampleBuffer: CMSampleBuffer) -> [Float] {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return [] }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &pointer
            ) == kCMBlockBufferNoErr, let pointer else { return [] }
            let count = length / MemoryLayout<Float>.size
            return pointer.withMemoryRebound(to: Float.self, capacity: count) {
                Array(UnsafeBufferPointer(start: $0, count: count))
            }
        }

        // Microphone-only passthrough: int16 mono in, canonical float stereo
        // out, amplitude preserved through the converter.
        let toneAmplitude = 8_000.0 / 32_768.0
        var micBuffer = try syntheticAudioSampleBuffer(startFrame: 0, frameCount: 1_600, sampleRate: 48_000)
        mixer.addMicrophone(micBuffer)
        guard mixed.count == 1 else { throw SelfTestError.audioMixWrongOutput }
        let passthrough = floatSamples(mixed[0])
        guard passthrough.count == 1_600 * 2 else { throw SelfTestError.audioMixWrongOutput }
        let passthroughPeak = passthrough.map(abs).max() ?? 0
        guard abs(Double(passthroughPeak) - toneAmplitude) < 0.02 else {
            throw SelfTestError.audioMixWrongOutput
        }

        // Mixing: a constant 0.25 system signal under the same tone. Peaks add
        // where the tone crests; troughs sit at the offset alone.
        mixed.removeAll()
        mixer.setSystemAudioEnabled(true)
        let systemBuffer = try syntheticSystemAudioBuffer(
            startFrame: 48_000, frameCount: 4_800, value: 0.25
        )
        mixer.addSystemAudio(systemBuffer)
        micBuffer = try syntheticAudioSampleBuffer(startFrame: 48_000, frameCount: 1_600, sampleRate: 48_000)
        mixer.addMicrophone(micBuffer)
        guard mixed.count == 1 else { throw SelfTestError.audioMixWrongOutput }
        let combined = floatSamples(mixed[0])
        let combinedPeak = combined.map(abs).max() ?? 0
        let expectedPeak = toneAmplitude + 0.25
        guard abs(Double(combinedPeak) - expectedPeak) < 0.03 else {
            throw SelfTestError.audioMixWrongOutput
        }
        let mean = combined.reduce(0, +) / Float(combined.count)
        guard abs(Double(mean) - 0.25) < 0.02 else { throw SelfTestError.audioMixWrongOutput }

        // The limiter: two loud sources summing far past full scale must come
        // out squeezed under 1.0, not wrapped or clipped square.
        guard AudioMixer.limited(1.8).magnitude < 1.0,
              AudioMixer.limited(-1.8).magnitude < 1.0,
              AudioMixer.limited(0.5) == 0.5
        else { throw SelfTestError.audioMixWrongOutput }

        // Without a microphone the mixer is system-driven: system buffers emit
        // directly instead of waiting for a mic cadence that will never come.
        mixed.removeAll()
        mixer.microphonePresent = false
        let directBuffer = try syntheticSystemAudioBuffer(
            startFrame: 144_000, frameCount: 1_600, value: 0.3
        )
        mixer.addSystemAudio(directBuffer)
        guard mixed.count == 1 else { throw SelfTestError.audioMixWrongOutput }
        let direct = floatSamples(mixed[0])
        guard direct.count == 1_600 * 2,
              abs(Double(direct.max() ?? 0) - 0.3) < 0.01
        else { throw SelfTestError.audioMixWrongOutput }
        mixer.microphonePresent = true

        // Disabling flushes back to passthrough.
        mixed.removeAll()
        mixer.setSystemAudioEnabled(false)
        micBuffer = try syntheticAudioSampleBuffer(startFrame: 96_000, frameCount: 1_600, sampleRate: 48_000)
        mixer.addMicrophone(micBuffer)
        guard mixed.count == 1 else { throw SelfTestError.audioMixWrongOutput }
        let restored = floatSamples(mixed[0])
        let restoredMean = restored.reduce(0, +) / Float(restored.count)
        guard abs(restoredMean) < 0.01 else { throw SelfTestError.audioMixWrongOutput }

        return String(format: "passthrough_peak=%.3f mixed_peak=%.3f", passthroughPeak, combinedPeak)
    }

    /// A canonical-format system-audio buffer holding a constant value — the
    /// easiest signal to assert against after mixing.
    private static func syntheticSystemAudioBuffer(
        startFrame: Int64,
        frameCount: Int,
        value: Float
    ) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            throw SelfTestError.audioSampleBufferFailed
        }
        let samples = [Float](repeating: value, count: frameCount * 2)
        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
            flags: 0, blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else {
            throw SelfTestError.audioSampleBufferFailed
        }
        let status = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: byteCount
            )
        }
        guard status == kCMBlockBufferNoErr else { throw SelfTestError.audioSampleBufferFailed }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: startFrame, timescale: 48_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = 8
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: formatDescription, sampleCount: frameCount,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            throw SelfTestError.audioSampleBufferFailed
        }
        return sampleBuffer
    }

    /// Writes a real movie through a real pause and checks what came out.
    ///
    /// The unit tests around `PauseClock` prove the arithmetic; this proves the
    /// arithmetic survives contact with AVAssetWriter. A paused stretch that is
    /// merely skipped rather than closed still produces a playable file — one
    /// that runs long and drifts out of sync — so the assertion is on the
    /// finished asset's duration, not on the timestamps going in.
    ///
    /// Timeline: one second recorded, two seconds paused, one second recorded.
    /// A correct file is two seconds long, not four.
    /// Waits for an input to accept data, with a deadline.
    ///
    /// A failed writer never becomes ready again and a stalled one never
    /// recovers, so spinning on the flag alone turns either into a hung test
    /// run rather than a report naming what went wrong.
    private static func waitForInput(_ input: AVAssetWriterInput, writer: AVAssetWriter) throws {
        let deadline = Date().addingTimeInterval(10)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw writer.error ?? SelfTestError.writerFailed }
            guard Date() < deadline else { throw SelfTestError.writerStalled }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    private static func verifyPausedRecording(format: VideoRecordingFormat) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oneact-pause-selftest.mov")
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: VideoEncoding.writerSettings(width: 320, height: 240, format: format)
        )
        // Matches the recorder: a live capture session feeds it, and a
        // non-realtime input expects to be pulled rather than pushed, which
        // stalls this loop regardless of pausing.
        videoInput.expectsMediaDataInRealTime = true
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000
            ]
        )
        audioInput.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 240,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else { throw writer.error ?? SelfTestError.writerStartFailed }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext()
        var clock = PauseClock()
        let audioFramesPerVideoFrame = 1_600 // 1/30 s at 48 kHz, so both tracks share a timeline
        var appendedVideoFrames = 0

        for frame in 0..<120 {
            if frame == 30 { clock.pause() }
            if frame == 90 { clock.resume() }

            let sourceTime = CMTime(value: CMTimeValue(frame), timescale: 30)
            guard let writerTime = clock.writerTime(for: sourceTime) else { continue }

            try waitForInput(videoInput, writer: writer)
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferCreate(
                nil, 320, 240, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                &pixelBuffer
            ) == kCVReturnSuccess, let pixelBuffer else { throw SelfTestError.pixelBufferFailed }
            let shade = CGFloat(frame % 30) / 30.0
            context.render(
                CIImage(color: CIColor(red: 0.2 + shade * 0.6, green: 0.3, blue: 0.6))
                    .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 240)),
                to: pixelBuffer
            )
            guard adaptor.append(pixelBuffer, withPresentationTime: writerTime) else {
                throw writer.error ?? SelfTestError.appendFailed
            }
            appendedVideoFrames += 1

            try waitForInput(audioInput, writer: writer)
            let audio = try syntheticAudioSampleBuffer(
                startFrame: Int64(frame) * Int64(audioFramesPerVideoFrame),
                frameCount: audioFramesPerVideoFrame,
                sampleRate: 48_000
            )
            // The same retiming the recorder applies, on the same clock.
            guard let shifted = retimedSampleBuffer(audio, offsetBy: clock.skipped) else {
                throw SelfTestError.pausedRetimeFailed
            }
            guard audioInput.append(shifted) else {
                throw writer.error ?? SelfTestError.audioAppendFailed
            }
        }

        videoInput.markAsFinished()
        audioInput.markAsFinished()
        let group = DispatchGroup()
        group.enter()
        writer.finishWriting { group.leave() }
        group.wait()
        guard writer.status == .completed else { throw writer.error ?? SelfTestError.writerFailed }

        guard appendedVideoFrames == 60 else { throw SelfTestError.pausedFrameCountWrong }

        let asset = AVURLAsset(url: url)
        let videoTracks = try loadTracks(from: asset, mediaType: .video)
        let audioTracks = try loadTracks(from: asset, mediaType: .audio)
        guard let videoTrack = videoTracks.first, let audioTrack = audioTracks.first else {
            throw SelfTestError.audioTrackMissing
        }
        let videoSeconds = videoTrack.timeRange.duration.seconds
        let audioSeconds = audioTrack.timeRange.duration.seconds

        // Four seconds of source time went in; the two paused seconds must not
        // be in the file.
        guard abs(videoSeconds - 2.0) < 0.1 else { throw SelfTestError.pausedDurationWrong }
        guard abs(audioSeconds - 2.0) < 0.15 else { throw SelfTestError.pausedDurationWrong }
        // Tracks that drifted apart across the pause would play out of sync
        // even though each one looks plausible on its own.
        guard abs(videoSeconds - audioSeconds) < 0.1 else { throw SelfTestError.pausedTracksDesynced }

        try? FileManager.default.removeItem(at: url)
        return String(format: "video=%.2fs audio=%.2fs frames=%d", videoSeconds, audioSeconds, appendedVideoFrames)
    }

    private static func verifySoftwareZoomCrop() throws {
        let sourceWidth: CGFloat = 192
        let sourceHeight: CGFloat = 108
        let background = CIImage(color: CIColor(red: 0.08, green: 0.12, blue: 0.9)).cropped(
            to: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        )
        let centerStripe = CIImage(color: CIColor(red: 0.9, green: 0.08, blue: 0.06)).cropped(
            to: CGRect(x: 78, y: 0, width: 36, height: sourceHeight)
        )
        let source = centerStripe.composited(over: background)
        let context = CIContext(options: [.useSoftwareRenderer: true])

        func sample(
            zoom: CGFloat,
            x: Int = 2,
            y: Int = 96
        ) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                nil,
                108,
                192,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                &buffer
            )
            guard status == kCVReturnSuccess, let buffer else {
                throw SelfTestError.pixelBufferFailed
            }
            context.render(
                FrameCompositor.aspectFill(source, width: 108, height: 192, zoom: zoom),
                to: buffer
            )
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
                throw SelfTestError.pixelBufferFailed
            }
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            return (red: bytes[offset + 2], green: bytes[offset + 1], blue: bytes[offset])
        }

        // 1× fills the canvas from the middle of the frame, 2× crops further in.
        let unzoomed = try sample(zoom: 1)
        let zoomed = try sample(zoom: 2)
        // Below 1× the crop would reach past the sensor image, so it is clamped
        // to 1× and must render identically.
        let clamped = try sample(zoom: 0.5)

        guard unzoomed.blue > unzoomed.red,
              zoomed.red > zoomed.blue,
              clamped == unzoomed else {
            fputs(
                "SOFTWARE_ZOOM_DIAGNOSTIC one=\(unzoomed) two=\(zoomed) clamped=\(clamped)\n",
                stderr
            )
            throw SelfTestError.softwareZoomCropFailed
        }
    }

    private static func verifyScreenCameraComposition() throws {
        let screen = CIImage(color: CIColor(red: 0.05, green: 0.15, blue: 0.9)).cropped(
            to: CGRect(x: 0, y: 0, width: 320, height: 180)
        )
        let camera = CIImage(color: CIColor(red: 0.9, green: 0.08, blue: 0.05)).cropped(
            to: CGRect(x: 0, y: 0, width: 160, height: 90)
        )
        let composed = FrameCompositor.screenWithCamera(
            screen: screen,
            camera: camera,
            width: 1080,
            height: 1920,
            cameraZoom: 1,
            position: .bottomRight
        )
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            1080,
            1920,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw SelfTestError.pixelBufferFailed
        }
        CIContext(options: [.useSoftwareRenderer: true]).render(composed, to: buffer)

        func color(atX x: Int, y: Int) throws -> (red: UInt8, blue: UInt8) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
                throw SelfTestError.pixelBufferFailed
            }
            let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            return (red: bytes[offset + 2], blue: bytes[offset])
        }

        let screenPixel = try color(atX: 540, y: 960)
        // Core Image uses a lower-left origin while the BGRA memory rows are top-down.
        let cameraPixel = try color(atX: 800, y: 1_760)
        guard screenPixel.blue > screenPixel.red, cameraPixel.red > cameraPixel.blue else {
            fputs(
                "SCREEN_CAMERA_DIAGNOSTIC screen_r=\(screenPixel.red) screen_b=\(screenPixel.blue) camera_r=\(cameraPixel.red) camera_b=\(cameraPixel.blue)\n",
                stderr
            )
            throw SelfTestError.screenCameraCompositionFailed
        }
    }

    private static func verifyCameraFrameStyles() throws {
        let canvasWidth = 1_080
        let canvasHeight = 1_920
        let screen = CIImage(color: CIColor(red: 0.05, green: 0.15, blue: 0.9)).cropped(
            to: CGRect(x: 0, y: 0, width: 320, height: 180)
        )
        let camera = CIImage(color: CIColor(red: 0.9, green: 0.08, blue: 0.05)).cropped(
            to: CGRect(x: 0, y: 0, width: 160, height: 90)
        )
        let context = CIContext(options: [.useSoftwareRenderer: true])

        func render(
            _ style: CameraFrameStyle,
            cameraImage: CIImage = camera,
            personBox: CGRect? = nil
        ) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                nil,
                canvasWidth,
                canvasHeight,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                &buffer
            )
            guard status == kCVReturnSuccess, let buffer else {
                throw SelfTestError.pixelBufferFailed
            }
            context.render(
                FrameCompositor.screenWithCamera(
                    screen: screen,
                    camera: cameraImage,
                    width: canvasWidth,
                    height: canvasHeight,
                    cameraZoom: 1,
                    position: .bottomRight,
                    // Fill leaves no letterbox, so anything not painted by the
                    // overlay is the screen image itself.
                    screenLayout: .fill,
                    cameraFrame: style,
                    personBox: personBox
                ),
                to: buffer
            )
            return buffer
        }

        // Core Image uses a lower-left origin while the BGRA memory rows are top-down.
        func pixel(
            _ buffer: CVPixelBuffer,
            x: Int,
            fromBottom y: Int
        ) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
                throw SelfTestError.pixelBufferFailed
            }
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            let offset = (canvasHeight - y) * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            return (red: bytes[offset + 2], green: bytes[offset + 1], blue: bytes[offset])
        }

        let margin = max(24, floor(min(CGFloat(canvasWidth), CGFloat(canvasHeight)) * 0.035))
        let rectSize = FrameCompositor.cameraOverlaySize(
            canvasWidth: CGFloat(canvasWidth),
            canvasHeight: CGFloat(canvasHeight),
            style: .rectangle
        )
        let circleSize = FrameCompositor.cameraOverlaySize(
            canvasWidth: CGFloat(canvasWidth),
            canvasHeight: CGFloat(canvasHeight),
            style: .circle
        )
        let rectOrigin = CGPoint(x: CGFloat(canvasWidth) - margin - rectSize.width, y: margin)
        let circleOrigin = CGPoint(x: CGFloat(canvasWidth) - margin - circleSize.width, y: margin)

        // A bordered rectangle paints white along the middle of its left edge.
        let rectBuffer = try render(.rectangle)
        let rectBorder = try pixel(
            rectBuffer,
            x: Int(rectOrigin.x) + 2,
            fromBottom: Int(rectOrigin.y + rectSize.height / 2)
        )
        // A circle leaves the corners of its bounding box to the screen.
        let circleBuffer = try render(.circle)
        let circleCenter = try pixel(
            circleBuffer,
            x: Int(circleOrigin.x + circleSize.width / 2),
            fromBottom: Int(circleOrigin.y + circleSize.height / 2)
        )
        let circleCorner = try pixel(
            circleBuffer,
            x: Int(circleOrigin.x) + 11,
            fromBottom: Int(circleOrigin.y) + 11
        )

        // Cutout: a person standing off to one side of the camera frame and
        // wider than the region a cutout is aimed at — the case the old layout
        // sliced, because it cropped the camera to that region before the mask
        // had any say. The mask is built as a real one-component buffer so the
        // box extractor is exercised on the same kind of data Vision returns.
        let maskWidth = 40
        let maskHeight = 23
        let maskBuffer = try monochromeMask(width: maskWidth, height: maskHeight) { row, column in
            // Right of centre, and standing on the bottom three quarters, so a
            // flipped row would show up as a box floating off the ground.
            column >= 25 && column < 35 && row >= 6
        }
        guard let measured = FrameCompositor.personBox(in: maskBuffer) else {
            fputs("CAMERA_FRAME_DIAGNOSTIC person_box=nil\n", stderr)
            throw SelfTestError.cameraFrameStyleFailed
        }
        let expectedBox = CGRect(
            x: 25 / CGFloat(maskWidth),
            y: 0,
            width: 10 / CGFloat(maskWidth),
            height: CGFloat(maskHeight - 6) / CGFloat(maskHeight)
        )
        let boxError = max(
            abs(measured.minX - expectedBox.minX),
            abs(measured.minY - expectedBox.minY),
            abs(measured.width - expectedBox.width),
            abs(measured.height - expectedBox.height)
        )

        let cutoutCamera = FrameCompositor.personCutout(
            camera: camera,
            mask: CIImage(cvPixelBuffer: maskBuffer)
        )
        let cutoutRegion = FrameCompositor.cameraOverlayFrame(
            canvasWidth: CGFloat(canvasWidth),
            canvasHeight: CGFloat(canvasHeight),
            style: .cutout,
            position: .bottomRight
        )
        let placement = FrameCompositor.cutoutPlacement(
            cameraExtent: camera.extent,
            personBox: measured,
            region: cutoutRegion,
            canvasWidth: CGFloat(canvasWidth),
            canvasHeight: CGFloat(canvasHeight)
        )
        let person = placement.personRect
        let cutoutBuffer = try render(.cutout, cameraImage: cutoutCamera, personBox: measured)
        let sampleRow = Int(person.midY)
        // Both edges of the person are painted: nothing between the mask and the
        // canvas is allowed to shorten them.
        let cutoutLeftEdge = try pixel(cutoutBuffer, x: Int(person.minX) + 10, fromBottom: sampleRow)
        let cutoutRightEdge = try pixel(cutoutBuffer, x: Int(person.maxX) - 10, fromBottom: sampleRow)
        // And everything around them is screen, not camera and not a border.
        let cutoutBeside = try pixel(cutoutBuffer, x: Int(person.minX) - 16, fromBottom: sampleRow)
        let cutoutDropped = try pixel(cutoutBuffer, x: Int(person.maxX) + 16, fromBottom: sampleRow)

        // The person is what gets aimed at the region, so an off-centre person
        // is centred on it rather than left wherever the camera framed them.
        let aimError = abs(person.midX - cutoutRegion.midX)
        // Full mask width survives to the canvas: 10 of 40 mask columns across a
        // camera frame scaled to the region's height.
        let expectedWidth = 0.25 * camera.extent.width * (cutoutRegion.height / camera.extent.height)

        // Flipping the camera moves the person to the other side of the frame,
        // and the box has to move with it. Because the placement is anchored on
        // the person, a flip that stays in step lands them in exactly the same
        // rectangle; one that does not puts them half a frame away.
        let mirroredBox = FrameCompositor.mirroredHorizontally(measured)
        let mirroredBuffer = try render(
            .cutout,
            cameraImage: FrameCompositor.mirroredHorizontally(cutoutCamera),
            personBox: mirroredBox
        )
        let mirroredLeftEdge = try pixel(mirroredBuffer, x: Int(person.minX) + 10, fromBottom: sampleRow)
        let mirroredRightEdge = try pixel(mirroredBuffer, x: Int(person.maxX) - 10, fromBottom: sampleRow)
        let mirroredBeside = try pixel(mirroredBuffer, x: Int(person.maxX) + 16, fromBottom: sampleRow)
        let roundTrip = FrameCompositor.mirroredHorizontally(mirroredBox)

        guard rectBorder.red > 180, rectBorder.green > 180, rectBorder.blue > 180,
              circleCenter.red > circleCenter.blue,
              circleCorner.blue > circleCorner.red,
              abs(roundTrip.minX - measured.minX) < 0.0001,
              abs(mirroredBox.minX - (1 - measured.maxX)) < 0.0001,
              mirroredLeftEdge.red > mirroredLeftEdge.blue,
              mirroredRightEdge.red > mirroredRightEdge.blue,
              mirroredBeside.blue > mirroredBeside.red,
              boxError < 0.02,
              aimError < 1,
              abs(person.width - expectedWidth) < 2,
              person.minX > 0, person.maxX < CGFloat(canvasWidth),
              cutoutLeftEdge.red > cutoutLeftEdge.blue,
              cutoutRightEdge.red > cutoutRightEdge.blue,
              cutoutBeside.blue > cutoutBeside.red,
              cutoutDropped.blue > cutoutDropped.red else {
            fputs(
                "CAMERA_FRAME_DIAGNOSTIC rect_border=\(rectBorder) circle_center=\(circleCenter) circle_corner=\(circleCorner) person_box=\(measured) box_error=\(boxError) person_rect=\(person) aim_error=\(aimError) expected_width=\(expectedWidth) cutout_left=\(cutoutLeftEdge) cutout_right=\(cutoutRightEdge) cutout_beside=\(cutoutBeside) cutout_dropped=\(cutoutDropped) mirrored_box=\(mirroredBox) mirrored_left=\(mirroredLeftEdge) mirrored_right=\(mirroredRightEdge) mirrored_beside=\(mirroredBeside)\n",
                stderr
            )
            throw SelfTestError.cameraFrameStyleFailed
        }
    }

    /// A one-component mask buffer filled by hand, matching what Vision hands
    /// back: rows run top-down, and a lit pixel is 255.
    private static func monochromeMask(
        width: Int,
        height: Int,
        lit: (_ row: Int, _ column: Int) -> Bool
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { throw SelfTestError.pixelBufferFailed }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw SelfTestError.pixelBufferFailed
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for column in 0..<width {
                bytes[row * bytesPerRow + column] = lit(row, column) ? 255 : 0
            }
        }
        return buffer
    }

    private static func verifyCameraPlacement() throws {
        let canvasWidth = 1_080
        let canvasHeight = 1_920
        // Left half red, right half blue, so panning the crop is visible.
        let screenRect = CGRect(x: 0, y: 0, width: 320, height: 180)
        let leftHalf = CIImage(color: CIColor(red: 0.9, green: 0.06, blue: 0.05)).cropped(
            to: CGRect(x: 0, y: 0, width: 160, height: 180)
        )
        let screen = leftHalf.composited(
            over: CIImage(color: CIColor(red: 0.05, green: 0.15, blue: 0.9)).cropped(to: screenRect)
        )
        let camera = CIImage(color: CIColor(red: 0.06, green: 0.9, blue: 0.1)).cropped(
            to: CGRect(x: 0, y: 0, width: 160, height: 90)
        )
        let context = CIContext(options: [.useSoftwareRenderer: true])

        func render(
            style: CameraFrameStyle,
            cameraOrigin: CGPoint? = nil,
            cameraScale: CGFloat = 1,
            screenCropOffset: CGPoint = .zero
        ) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                nil,
                canvasWidth,
                canvasHeight,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                &buffer
            )
            guard status == kCVReturnSuccess, let buffer else {
                throw SelfTestError.pixelBufferFailed
            }
            context.render(
                FrameCompositor.screenWithCamera(
                    screen: screen,
                    camera: camera,
                    width: canvasWidth,
                    height: canvasHeight,
                    cameraZoom: 1,
                    position: .bottomRight,
                    screenLayout: .fill,
                    cameraFrame: style,
                    cameraOrigin: cameraOrigin,
                    cameraScale: cameraScale,
                    screenCropOffset: screenCropOffset
                ),
                to: buffer
            )
            return buffer
        }

        func pixel(
            _ buffer: CVPixelBuffer,
            x: Int,
            fromBottom y: Int
        ) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
                throw SelfTestError.pixelBufferFailed
            }
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            let offset = (canvasHeight - y) * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            return (red: bytes[offset + 2], green: bytes[offset + 1], blue: bytes[offset])
        }

        let anchored = FrameCompositor.cameraOverlayFrame(
            canvasWidth: CGFloat(canvasWidth),
            canvasHeight: CGFloat(canvasHeight),
            style: .rectangle,
            position: .bottomRight
        )
        // Hidden leaves the corner to the screen.
        let hiddenCorner = try pixel(
            render(style: .hidden),
            x: Int(anchored.midX),
            fromBottom: Int(anchored.midY)
        )
        // A dragged origin moves the overlay away from that corner.
        let draggedOrigin = CGPoint(x: 90, y: 1_100)
        let draggedBuffer = try render(style: .rectangle, cameraOrigin: draggedOrigin)
        let dragged = FrameCompositor.cameraOverlayFrame(
            canvasWidth: CGFloat(canvasWidth),
            canvasHeight: CGFloat(canvasHeight),
            style: .rectangle,
            position: .bottomRight,
            origin: draggedOrigin
        )
        let atDraggedSpot = try pixel(draggedBuffer, x: Int(dragged.midX), fromBottom: Int(dragged.midY))
        let atOldSpot = try pixel(draggedBuffer, x: Int(anchored.midX), fromBottom: Int(anchored.midY))
        // A bigger overlay covers canvas that the default size leaves to the screen.
        let enlarged = FrameCompositor.cameraOverlaySize(
            canvasWidth: CGFloat(canvasWidth),
            canvasHeight: CGFloat(canvasHeight),
            style: .rectangle,
            scale: 1.5
        )
        let outsideDefault = CGPoint(x: anchored.minX - 120, y: anchored.midY)
        let atDefaultSize = try pixel(
            render(style: .rectangle),
            x: Int(outsideDefault.x),
            fromBottom: Int(outsideDefault.y)
        )
        let atLargeSize = try pixel(
            render(style: .rectangle, cameraScale: 1.5),
            x: Int(outsideDefault.x),
            fromBottom: Int(outsideDefault.y)
        )
        // Panning the screen swaps which half of it the canvas shows.
        let pannedLeft = try pixel(
            render(style: .hidden, screenCropOffset: CGPoint(x: -0.5, y: 0)),
            x: 540,
            fromBottom: 960
        )
        let pannedRight = try pixel(
            render(style: .hidden, screenCropOffset: CGPoint(x: 0.5, y: 0)),
            x: 540,
            fromBottom: 960
        )

        guard dragged.origin == draggedOrigin,
              enlarged.width == floor(anchored.width * 1.5),
              enlarged.height == floor(anchored.height * 1.5),
              atDefaultSize.green < 100,
              atLargeSize.green > atLargeSize.red,
              hiddenCorner.blue > hiddenCorner.green,
              atDraggedSpot.green > atDraggedSpot.blue,
              atOldSpot.blue > atOldSpot.green,
              pannedLeft.red > pannedLeft.blue,
              pannedRight.blue > pannedRight.red else {
            fputs(
                "CAMERA_PLACEMENT_DIAGNOSTIC hidden=\(hiddenCorner) dragged=\(atDraggedSpot) old_spot=\(atOldSpot) default_size=\(atDefaultSize) large_size=\(atLargeSize) pan_left=\(pannedLeft) pan_right=\(pannedRight)\n",
                stderr
            )
            throw SelfTestError.cameraPlacementFailed
        }
    }

    private static func verifyScreenLayoutModes() throws {
        let sourceRect = CGRect(x: 0, y: 0, width: 410, height: 898)
        let center = CIImage(color: CIColor(red: 0.08, green: 0.72, blue: 0.18)).cropped(to: sourceRect)
        let topBand = CIImage(color: CIColor(red: 0.92, green: 0.05, blue: 0.04)).cropped(
            to: CGRect(x: 0, y: 798, width: 410, height: 100)
        )
        let bottomBand = CIImage(color: CIColor(red: 0.04, green: 0.08, blue: 0.92)).cropped(
            to: CGRect(x: 0, y: 0, width: 410, height: 100)
        )
        let source = topBand.composited(over: bottomBand.composited(over: center))
        let context = CIContext(options: [.useSoftwareRenderer: true])

        func render(
            layout: ScreenLayoutMode,
            alignment: ScreenVerticalAlignment = .center,
            background: CIColor = .black
        ) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                nil,
                108,
                192,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                &buffer
            )
            guard status == kCVReturnSuccess, let buffer else {
                throw SelfTestError.pixelBufferFailed
            }
            context.render(
                FrameCompositor.screenCanvas(
                    source,
                    width: 108,
                    height: 192,
                    layout: layout,
                    verticalAlignment: alignment,
                    background: background
                ),
                to: buffer
            )
            return buffer
        }

        func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
                throw SelfTestError.pixelBufferFailed
            }
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            return (red: bytes[offset + 2], green: bytes[offset + 1], blue: bytes[offset])
        }

        let fitEdge = try pixel(render(layout: .fit), x: 2, y: 96)
        let whiteFitEdge = try pixel(
            render(layout: .fit, background: CIColor(red: 1, green: 1, blue: 1)),
            x: 2,
            y: 96
        )
        let fillEdge = try pixel(render(layout: .fill), x: 2, y: 96)
        let blurEdge = try pixel(render(layout: .blur), x: 2, y: 96)
        let topCrop = try pixel(render(layout: .fill, alignment: .top), x: 54, y: 5)
        let bottomCrop = try pixel(render(layout: .fill, alignment: .bottom), x: 54, y: 187)

        guard fitEdge.red < 15, fitEdge.green < 15, fitEdge.blue < 15,
              whiteFitEdge.red > 220, whiteFitEdge.green > 220, whiteFitEdge.blue > 220,
              fillEdge.green > 100,
              blurEdge.green > 35,
              topCrop.red > topCrop.green,
              bottomCrop.blue > bottomCrop.green else {
            fputs(
                "SCREEN_LAYOUT_DIAGNOSTIC fit=\(fitEdge) white_fit=\(whiteFitEdge) fill=\(fillEdge) blur=\(blurEdge) top=\(topCrop) bottom=\(bottomCrop)\n",
                stderr
            )
            throw SelfTestError.screenLayoutModeFailed
        }
    }

    /// A window capture arrives with transparent rounded corners. Every layout
    /// must flatten those onto the canvas backdrop; leaving them transparent
    /// would let the recycled pixel buffer's previous contents show through.
    private static func verifyTransparentSourceCorners() throws {
        let sourceRect = CGRect(x: 0, y: 0, width: 200, height: 200)
        // Opaque green square with a transparent band along the left edge,
        // standing in for a rounded corner's alpha.
        let opaquePart = CIImage(color: CIColor(red: 0.05, green: 0.85, blue: 0.1)).cropped(
            to: CGRect(x: 40, y: 0, width: 160, height: 200)
        )
        let source = opaquePart.cropped(to: sourceRect)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let white = CIColor(red: 1, green: 1, blue: 1)

        func cornerPixel(layout: ScreenLayoutMode) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                nil,
                200,
                200,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                &buffer
            )
            guard status == kCVReturnSuccess, let buffer else {
                throw SelfTestError.pixelBufferFailed
            }
            // Prime the buffer with magenta: anything the canvas fails to cover
            // shows up as magenta rather than as a plausible-looking colour.
            context.render(
                CIImage(color: CIColor(red: 1, green: 0, blue: 1)).cropped(to: sourceRect),
                to: buffer
            )
            context.render(
                FrameCompositor.screenCanvas(
                    source,
                    width: 200,
                    height: 200,
                    layout: layout,
                    verticalAlignment: .center,
                    background: white
                ),
                to: buffer
            )
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
                throw SelfTestError.pixelBufferFailed
            }
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            let offset = 100 * CVPixelBufferGetBytesPerRow(buffer) + 4 * 4
            return (red: bytes[offset + 2], green: bytes[offset + 1], blue: bytes[offset])
        }

        let fit = try cornerPixel(layout: .fit)
        let fill = try cornerPixel(layout: .fill)
        let blur = try cornerPixel(layout: .blur)
        // Transparent source area must read as backdrop-ish, never as the
        // magenta that was sitting in the buffer.
        let leaked = { (p: (red: UInt8, green: UInt8, blue: UInt8)) in
            p.red > 200 && p.green < 80 && p.blue > 200
        }
        guard !leaked(fit), !leaked(fill), !leaked(blur),
              fit.red > 200, fit.green > 200, fit.blue > 200 else {
            fputs(
                "TRANSPARENT_CORNER_DIAGNOSTIC fit=\(fit) fill=\(fill) blur=\(blur)\n",
                stderr
            )
            throw SelfTestError.transparentCornerFailed
        }
    }

    private static func verifyScreenStreamGeometry() throws {
        let phoneWindow = ScreenStreamGeometry.outputDimensions(
            contentRect: CGRect(x: 0, y: 0, width: 410, height: 898),
            pointPixelScale: 2
        )
        let sourceRatio = 410.0 / 898.0
        let outputRatio = Double(phoneWindow.width) / Double(phoneWindow.height)

        let oversizedWindow = ScreenStreamGeometry.outputDimensions(
            contentRect: CGRect(x: 0, y: 0, width: 5_000, height: 2_500),
            pointPixelScale: 1
        )

        guard phoneWindow == ScreenStreamDimensions(width: 820, height: 1_796),
              abs(sourceRatio - outputRatio) < 0.001,
              oversizedWindow == ScreenStreamDimensions(width: 3_840, height: 1_920) else {
            throw SelfTestError.screenStreamGeometryFailed
        }
    }

    /// The camera's half of what `verifyScreenStreamGeometry` covers for the
    /// screen: the source has to be captured in the shape the canvas will crop
    /// it to, not in whatever shape a default preset prefers.
    ///
    /// The list is a real one — the formats a FaceTime HD Camera reports — so a
    /// regression here reads as the wrong choice on hardware that exists rather
    /// than on a shape invented to make the test pass.
    @discardableResult
    private static func verifyCameraFormatSelection() throws -> String {
        let faceTimeHD = [
            CameraFormatCandidate(width: 1_920, height: 1_080, maximumFrameRate: 30),
            CameraFormatCandidate(width: 1_280, height: 720, maximumFrameRate: 30),
            CameraFormatCandidate(width: 1_080, height: 1_920, maximumFrameRate: 30),
            CameraFormatCandidate(width: 1_760, height: 1_328, maximumFrameRate: 30),
            CameraFormatCandidate(width: 640, height: 480, maximumFrameRate: 30),
            CameraFormatCandidate(width: 1_328, height: 1_760, maximumFrameRate: 30),
            CameraFormatCandidate(width: 1_552, height: 1_552, maximumFrameRate: 30)
        ]

        func chosen(canvasWidth: Int, canvasHeight: Int) -> CameraFormatCandidate? {
            CameraFormatSelection.bestIndex(
                among: faceTimeHD,
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight
            ).map { faceTimeHD[$0] }
        }

        // Every canvas ratio the app offers, at its High resolution, takes the
        // format shaped like it — not the largest format, and not the same
        // landscape one every time.
        let landscape = chosen(canvasWidth: 2_560, canvasHeight: 1_440)
        // The portrait case is the one that shipped broken: a 16:9 format here
        // survives the crop as 607 x 1080 and is then blown up 2.4x.
        let portrait = chosen(canvasWidth: 1_440, canvasHeight: 2_560)
        let square = chosen(canvasWidth: 1_440, canvasHeight: 1_440)
        let social = chosen(canvasWidth: 1_440, canvasHeight: 1_800)
        let classic = chosen(canvasWidth: 1_920, canvasHeight: 1_440)

        guard landscape == CameraFormatCandidate(width: 1_920, height: 1_080, maximumFrameRate: 30),
              portrait == CameraFormatCandidate(width: 1_080, height: 1_920, maximumFrameRate: 30),
              square == CameraFormatCandidate(width: 1_552, height: 1_552, maximumFrameRate: 30),
              social == CameraFormatCandidate(width: 1_328, height: 1_760, maximumFrameRate: 30),
              classic == CameraFormatCandidate(width: 1_760, height: 1_328, maximumFrameRate: 30) else {
            throw SelfTestError.cameraFormatSelectionFailed
        }

        // Lowering the canvas resolution must not change the answer: the choice
        // is about shape, and a 720p canvas still wants the fullest crop it can
        // get so the downscale has something to average.
        guard chosen(canvasWidth: 720, canvasHeight: 1_280) == portrait else {
            throw SelfTestError.cameraFormatSelectionFailed
        }

        // A format that cannot hold 30fps loses to a smaller one that can,
        // however many pixels it carries.
        let slowAndLarge = [
            CameraFormatCandidate(width: 3_840, height: 2_160, maximumFrameRate: 24),
            CameraFormatCandidate(width: 1_280, height: 720, maximumFrameRate: 60)
        ]
        guard CameraFormatSelection.bestIndex(
            among: slowAndLarge,
            canvasWidth: 1_920,
            canvasHeight: 1_080
        ) == 1 else {
            throw SelfTestError.cameraFormatSelectionFailed
        }

        // When nothing reaches 30fps the camera still gets a format. Leaving the
        // session unconfigured to protect a frame rate would trade a slow
        // recording for no recording.
        let allSlow = [
            CameraFormatCandidate(width: 640, height: 480, maximumFrameRate: 15),
            CameraFormatCandidate(width: 1_920, height: 1_080, maximumFrameRate: 15)
        ]
        guard CameraFormatSelection.bestIndex(
            among: allSlow,
            canvasWidth: 1_920,
            canvasHeight: 1_080
        ) == 1 else {
            throw SelfTestError.cameraFormatSelectionFailed
        }

        // Two formats that survive the crop identically: the one that reads
        // fewer pixels to get there wins, since the rest is cropped away every
        // frame regardless.
        let sameCropDifferentWaste = [
            CameraFormatCandidate(width: 1_920, height: 1_440, maximumFrameRate: 30),
            CameraFormatCandidate(width: 1_920, height: 1_080, maximumFrameRate: 30)
        ]
        guard CameraFormatSelection.bestIndex(
            among: sameCropDifferentWaste,
            canvasWidth: 1_920,
            canvasHeight: 1_080
        ) == 1 else {
            throw SelfTestError.cameraFormatSelectionFailed
        }

        guard CameraFormatSelection.bestIndex(
            among: [],
            canvasWidth: 1_920,
            canvasHeight: 1_080
        ) == nil else {
            throw SelfTestError.cameraFormatSelectionFailed
        }

        func describe(_ candidate: CameraFormatCandidate?) -> String {
            candidate.map { "\($0.width)x\($0.height)" } ?? "none"
        }
        return "16:9=\(describe(landscape)) 9:16=\(describe(portrait)) 1:1=\(describe(square)) 4:5=\(describe(social)) 4:3=\(describe(classic))"
    }

    private static func verifyCameraOutputLimit() throws {
        let cases: [(Int, Int, Int, Int, CGFloat, Int, Int)] = [
            (2560, 1440, 1920, 1080, 1, 1920, 1080),
            (1440, 2560, 1080, 1920, 1, 1080, 1920),
            (1440, 1440, 1552, 1552, 1, 1440, 1440),
            (1440, 2560, 1920, 1080, 1, 594, 1056),
            (1920, 1080, 1920, 1080, 2, 960, 540),
            (2560, 1440, 640, 480, 1, 640, 360),
            (1920, 1440, 1760, 1328, 1, 1760, 1320)
        ]
        for (w, h, sw, sh, zoom, ew, eh) in cases {
            let size = CameraOutputSizing.limited(width: w, height: h, sourceWidth: sw, sourceHeight: sh, zoom: zoom)
            guard size.width == ew, size.height == eh,
                  size.width * h == size.height * w,
                  Double(size.width) * Double(zoom) <= Double(sw) + 0.001,
                  Double(size.height) * Double(zoom) <= Double(sh) + 0.001 else {
                throw SelfTestError.cameraOutputLimitFailed
            }
        }
    }

    private static func verifyLanczosUpscaling() throws {
        let bounds = CGRect(x: 0, y: 0, width: 64, height: 32)
        let source = CIImage(color: .white).cropped(to: CGRect(x: 32, y: 0, width: 32, height: 32))
            .composited(over: CIImage(color: .black).cropped(to: bounds))
        let enlarged = FrameCompositor.aspectFill(source, width: 256, height: 128)
        let affine = source.transformed(by: CGAffineTransform(scaleX: 4, y: 4))
        let target = CGRect(x: 0, y: 0, width: 256, height: 128)
        let context = CIContext()
        func pixels(_ image: CIImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 256 * 128 * 4)
            context.render(image, toBitmap: &bytes, rowBytes: 256 * 4, bounds: target,
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return bytes
        }
        let lanczos = pixels(enlarged), baseline = pixels(affine)
        let row = 64 * 256 * 4
        let difference = (120..<136).reduce(0) { $0 + abs(Int(lanczos[row + $1 * 4]) - Int(baseline[row + $1 * 4])) }
        guard enlarged.extent == target, difference > 8,
              lanczos[3] == 255, lanczos[lanczos.count - 1] == 255 else {
            throw SelfTestError.lanczosUpscaleFailed
        }
    }

    /// Compare known sRGB patches after render -> encode -> Apple decode ->
    /// sRGB. Checking only the writer tags or source/preencode PNGs misses an
    /// ICC/video-transfer mismatch: both can agree before the movie is decoded.
    private static func verifyVideoColorRoundTrip(format: VideoRecordingFormat) throws -> String {
        let width = 768, height = 512
        let colors: [[UInt8]] = [
            [0, 0, 0], [16, 16, 16], [32, 32, 32], [64, 64, 64],
            [96, 96, 96], [128, 128, 128], [160, 160, 160], [192, 192, 192],
            [224, 224, 224], [255, 255, 255], [190, 135, 110], [145, 96, 39],
            [200, 50, 50], [50, 180, 70], [40, 80, 200], [40, 180, 180]
        ]
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = colors[(y / 128) * 4 + x / 192]
                let offset = (y * width + x) * 4
                for channel in 0..<3 { rgba[offset + channel] = color[channel] }
            }
        }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let image = CIImage(bitmapData: Data(rgba), bytesPerRow: width * 4,
                            size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: srgb)
        let context = CIContext()
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                                  &buffer) == kCVReturnSuccess, let buffer else {
            throw SelfTestError.pixelBufferFailed
        }
        VideoEncoding.render(image, to: buffer, using: context)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oneact-color-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video,
            outputSettings: VideoEncoding.writerSettings(width: width, height: height, format: format))
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.startWriting() else { throw writer.error ?? SelfTestError.writerStartFailed }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            try waitForInput(input, writer: writer)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? SelfTestError.appendFailed
            }
        }
        input.markAsFinished()
        let finished = DispatchGroup()
        finished.enter()
        writer.finishWriting { finished.leave() }
        guard finished.wait(timeout: .now() + 15) == .success, writer.status == .completed else {
            throw writer.error ?? SelfTestError.writerFailed
        }
        let asset = AVURLAsset(url: url)
        guard let track = try loadTracks(from: asset, mediaType: .video).first else {
            throw SelfTestError.decodedFrameMissing
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        defer { reader.cancelReading() }
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
              let decoded = CMSampleBufferGetImageBuffer(sample) else {
            throw reader.error ?? SelfTestError.decodedFrameMissing
        }
        var decodedRGBA = [UInt8](repeating: 0, count: width * height * 4)
        decodedRGBA.withUnsafeMutableBytes { bytes in
            context.render(CIImage(cvPixelBuffer: decoded), toBitmap: bytes.baseAddress!,
                           rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBA8, colorSpace: srgb)
        }
        var maximumError = 0
        for (index, color) in colors.enumerated() {
            let x = (index % 4) * 192 + 96, y = (index / 4) * 128 + 64
            let offset = (y * width + x) * 4
            for channel in 0..<3 {
                maximumError = max(maximumError, abs(Int(decodedRGBA[offset + channel]) - Int(color[channel])))
            }
        }
        guard maximumError <= 4 else { throw SelfTestError.videoColorRoundTripFailed(maximumError) }
        return "maxRGBError=\(maximumError)/255"
    }

    /// The three ways a width-keyed bit rate went wrong, each pinned to the
    /// canvas presets that exposed it.
    private static func verifyVideoBitRate() throws {
        let landscape1440 = VideoEncoding.bitRate(width: 2_560, height: 1_440)
        let portrait1440 = VideoEncoding.bitRate(width: 1_440, height: 2_560)
        let landscape1080 = VideoEncoding.bitRate(width: 1_920, height: 1_080)
        let social1440 = VideoEncoding.bitRate(width: 1_440, height: 1_800)
        let uhd = VideoEncoding.bitRate(width: 3_840, height: 2_160)

        // Rotating a canvas moves no pixels, so it may not move the bit rate.
        guard landscape1440 == portrait1440 else { throw SelfTestError.videoBitRateFailed }
        // 4:5 at 1440p carries more pixels than 16:9 at 1080p despite being
        // narrower, and has to be paid more rather than less.
        guard social1440 > landscape1080 else { throw SelfTestError.videoBitRateFailed }
        // Four times the pixels earns four times the bits instead of saturating.
        guard abs(Double(uhd) / Double(landscape1080) - 4) < 0.01 else {
            throw SelfTestError.videoBitRateFailed
        }
    }

    private static func syntheticAudioSampleBuffer(
        startFrame: Int64,
        frameCount: Int,
        sampleRate: Int32
    ) throws -> CMSampleBuffer {
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            throw SelfTestError.audioSampleBufferFailed
        }

        var samples = [Int16](repeating: 0, count: frameCount)
        for index in 0..<frameCount {
            let position = Double(startFrame + Int64(index)) / Double(sampleRate)
            samples[index] = Int16(sin(position * 2.0 * .pi * 440.0) * 8_000.0)
        }
        let byteCount = samples.count * MemoryLayout<Int16>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else {
            throw SelfTestError.audioSampleBufferFailed
        }
        let copyStatus = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { throw SelfTestError.audioSampleBufferFailed }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: CMTime(value: startFrame, timescale: sampleRate),
            decodeTimeStamp: .invalid
        )
        var sampleSize = MemoryLayout<Int16>.size
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            throw SelfTestError.audioSampleBufferFailed
        }
        return sampleBuffer
    }

    private static func assetContainsAudio(url: URL) -> Bool {
        ((try? loadTracks(from: AVURLAsset(url: url), mediaType: .audio)) ?? []).isEmpty == false
    }

    /// The synchronous `tracks(withMediaType:)` deadlocks here every few runs, so
    /// the async loader is driven from a detached task and waited on instead.
    private static func loadTracks(
        from asset: AVURLAsset,
        mediaType: AVMediaType
    ) throws -> [AVAssetTrack] {
        let semaphore = DispatchSemaphore(value: 0)
        let box = TrackBox()
        Task.detached {
            do {
                box.result = .success(try await asset.loadTracks(withMediaType: mediaType))
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            throw SelfTestError.decodedFrameMissing
        }
        return try (box.result ?? .success([])).get()
    }

    private static func decodedAverageLuma(url: URL) throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try loadTracks(from: asset, mediaType: .video).first else {
            throw SelfTestError.decodedFrameMissing
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        guard reader.canAdd(output) else { throw SelfTestError.decodedFrameMissing }
        reader.add(output)
        guard reader.startReading(),
              let sampleBuffer = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw SelfTestError.decodedFrameMissing
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw SelfTestError.decodedFrameMissing
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        let stepX = max(1, width / 64)
        let stepY = max(1, height / 64)
        var total = 0.0
        var count = 0
        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: width, by: stepX) {
                let offset = y * bytesPerRow + x * 4
                let blue = Double(bytes[offset])
                let green = Double(bytes[offset + 1])
                let red = Double(bytes[offset + 2])
                total += (red + green + blue) / (3.0 * 255.0)
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
    }
}

enum DeviceReport {
    static func run() -> Int32 {
        let videoSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        let audioSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        print("DEVICE_REPORT video_count=\(videoSession.devices.count) audio_count=\(audioSession.devices.count)")
        for device in videoSession.devices {
            let format = device.activeFormat
            var backgroundSupported = false
            if #available(macOS 15.0, *) { backgroundSupported = format.isBackgroundReplacementSupported }
            print("VIDEO name=\(device.localizedName) continuity=\(device.isContinuityCamera) portrait=\(format.isPortraitEffectSupported) studio_light=\(format.isStudioLightSupported) background=\(backgroundSupported) center_stage=\(format.isCenterStageSupported)")
            // Dimensions are what this report was missing when a portrait
            // canvas turned out to be recording a sliver of a landscape frame:
            // nothing here said what shapes the camera could actually deliver.
            let active = CameraFormatCandidate(format)
            let available = device.formats
                .map(CameraFormatCandidate.init)
                .map { "\($0.width)x\($0.height)@\(Int($0.maximumFrameRate))" }
                .joined(separator: ",")
            print("  FORMATS active=\(active.width)x\(active.height)@\(Int(active.maximumFrameRate)) available=\(available)")
        }
        for device in audioSession.devices { print("AUDIO name=\(device.localizedName)") }
        return 0
    }
}

private final class TrackBox: @unchecked Sendable {
    var result: Result<[AVAssetTrack], Error>?
}

private enum SelfTestError: LocalizedError {
    case writerStartFailed
    case pixelBufferFailed
    case appendFailed
    case writerFailed
    case decodedFrameMissing
    case blackFrame
    case softwareZoomCropFailed
    case screenCameraCompositionFailed
    case cameraFrameStyleFailed
    case cameraPlacementFailed
    case screenLayoutModeFailed
    case transparentCornerFailed
    case screenStreamGeometryFailed
    case cameraFormatSelectionFailed
    case videoBitRateFailed
    case videoColorRoundTripFailed(Int)
    case cameraOutputLimitFailed
    case lanczosUpscaleFailed
    case audioWriterInputFailed
    case audioSampleBufferFailed
    case audioAppendFailed
    case audioTrackMissing
    case pausedRetimeFailed
    case pausedFrameCountWrong
    case pausedDurationWrong
    case pausedTracksDesynced
    case writerStalled
    case audioMixWrongOutput

    var errorDescription: String? {
        switch self {
        case .writerStartFailed: "writer start failed"
        case .pixelBufferFailed: "pixel buffer allocation failed"
        case .appendFailed: "pixel buffer append failed"
        case .writerFailed: "writer failed"
        case .decodedFrameMissing: "could not decode a frame from the output movie"
        case .blackFrame: "decoded output frame is black"
        case .softwareZoomCropFailed: "software zoom did not crop toward the center as expected, or did not clamp below 1×"
        case .screenCameraCompositionFailed: "screen and camera picture-in-picture composition failed"
        case .cameraFrameStyleFailed: "camera frame style (rectangle, circle, or cutout) did not render as expected"
        case .cameraPlacementFailed: "hidden camera, dragged placement, overlay size, or screen panning did not render as expected"
        case .screenLayoutModeFailed: "Fit, Fill, Blur, or crop alignment did not render as expected"
        case .transparentCornerFailed: "a transparent source corner was not flattened onto the canvas backdrop"
        case .screenStreamGeometryFailed: "screen stream dimensions did not preserve the selected content ratio"
        case .cameraFormatSelectionFailed: "the camera format chosen was not the one that best survives the canvas crop"
        case .videoColorRoundTripFailed(let difference): "video color changed after encode/decode: max RGB error \(difference)/255"
        case .videoBitRateFailed: "video bit rate did not follow the canvas pixel throughput"
        case .cameraOutputLimitFailed: "camera output exceeded the effective source pixels or changed the canvas ratio"
        case .lanczosUpscaleFailed: "magnification did not use the Lanczos kernel or introduced transparent edges"
        case .audioWriterInputFailed: "audio writer input could not be added"
        case .audioSampleBufferFailed: "could not create a synthetic audio sample buffer"
        case .audioAppendFailed: "synthetic audio append failed"
        case .audioTrackMissing: "encoded output is missing its audio track"
        case .pausedRetimeFailed: "could not retime a sample buffer across a pause"
        case .pausedFrameCountWrong: "frames written across a pause did not match the unpaused stretches"
        case .pausedDurationWrong: "a paused recording kept the paused time in the file instead of closing the gap"
        case .pausedTracksDesynced: "video and audio drifted apart across a pause"
        case .writerStalled: "an asset writer input stopped accepting data"
        case .audioMixWrongOutput: "the audio mixer produced output that does not match its inputs"
        }
    }
}
