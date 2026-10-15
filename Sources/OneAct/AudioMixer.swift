import AVFoundation
import CoreMedia

/// Mixes the microphone with the shared screen's system audio into the single
/// track the file carries.
///
/// One track, mixed before the writer, because the file must play everywhere
/// without editing: QuickTime plays multiple audio tracks, but upload
/// pipelines routinely keep only the first, which would silently drop the
/// system audio — locally fine, published broken. The two sources stay
/// independent inputs in here (own gain, own gate) so a split-track export can
/// be added later without rearchitecting.
///
/// Everything runs on the recorder's capture queue; there is no locking. The
/// microphone drives the cadence: each mic buffer is converted to the
/// canonical format and — when system audio is on — summed against the ring
/// buffer of system audio, delayed by a small jitter budget so the matching
/// system samples have arrived. Timestamps pass through from the mic buffer,
/// so the pause clock downstream treats mixed audio exactly like mic audio.
final class AudioMixer {
    /// Mixed output format: what ScreenCaptureKit already delivers, and a
    /// fixed target for every microphone via one conversion. A constant
    /// format for the whole file also makes mid-take toggling safe — the
    /// writer never sees the stream change shape.
    static let sampleRate = 48_000.0
    static let channelCount = 2

    var onMixedBuffer: ((CMSampleBuffer) -> Void)?
    private(set) var systemAudioEnabled = false
    /// Whether a microphone is feeding the mixer. The mic drives the cadence
    /// when present; with the mic intentionally off there is no cadence to
    /// follow, so system buffers emit directly as they arrive.
    var microphonePresent = true

    var microphoneGain: Float = 1
    var systemGain: Float = 1

    private let canonicalFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: AVAudioChannelCount(channelCount),
        interleaved: true
    )!
    private var canonicalDescription: CMAudioFormatDescription?
    private var microphoneConverter: AVAudioConverter?
    private var microphoneSourceFormat: AVAudioFormat?
    private var systemConverter: AVAudioConverter?
    private var systemSourceFormat: AVAudioFormat?

    /// System audio ring, interleaved stereo, indexed by absolute frame number
    /// derived from host-clock timestamps — the clock both capture pipelines
    /// stamp with, which is what lets a mic frame find its system frame.
    private let ringFrames = 4 * 48_000
    private var ring: [Float]
    /// Next absolute frame the system stream will write. Writes are sequential
    /// against this counter rather than each buffer's own timestamp, so
    /// per-buffer timestamp jitter cannot punch one-frame holes that tick at
    /// 50 Hz; the counter re-anchors only when the stream genuinely jumps.
    private var systemNextFrame: Int64 = 0
    /// Absolute frame the system stream has filled up to (exclusive).
    private var systemHighWater: Int64 = 0

    private struct PendingMicrophoneBuffer {
        let presentationTime: CMTime
        let samples: [Float]
    }
    private var pending: [PendingMicrophoneBuffer] = []
    /// How long a mic buffer waits for its system audio before mixing with
    /// silence — covers delivery jitter without adding audible latency
    /// anywhere (timestamps are unchanged; only processing is deferred).
    private let jitterBudget = 0.25

    init() {
        ring = [Float](repeating: 0, count: ringFrames * Self.channelCount)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &canonicalDescription
        )
    }

    func setSystemAudioEnabled(_ enabled: Bool) {
        guard enabled != systemAudioEnabled else { return }
        if !enabled {
            // Whatever is queued mixes with what the ring already has; from
            // the next mic buffer on, output is microphone-only again.
            flushPending(force: true)
            systemNextFrame = 0
            systemHighWater = 0
        }
        systemAudioEnabled = enabled
    }

    func addMicrophone(_ sampleBuffer: CMSampleBuffer) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid,
              let samples = convertToCanonical(
                  sampleBuffer,
                  converter: &microphoneConverter,
                  sourceFormat: &microphoneSourceFormat
              )
        else {
            // A conversion failure must not cost the take its audio: hand the
            // original buffer through — the writer converts formats itself.
            onMixedBuffer?(sampleBuffer)
            return
        }
        if systemAudioEnabled {
            pending.append(PendingMicrophoneBuffer(presentationTime: presentationTime, samples: samples))
            flushPending(force: false)
        } else {
            emit(samples: scaled(samples, by: microphoneGain), at: presentationTime)
        }
    }

    func addSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard systemAudioEnabled else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid,
              let samples = convertToCanonical(
                  sampleBuffer,
                  converter: &systemConverter,
                  sourceFormat: &systemSourceFormat
              )
        else { return }

        guard microphonePresent else {
            emit(samples: scaled(samples, by: systemGain), at: presentationTime)
            return
        }

        let stampedFrame = Int64((presentationTime.seconds * Self.sampleRate).rounded())
        // Re-anchor on a genuine discontinuity (first buffer, source change);
        // otherwise keep writing sequentially so timestamp jitter cannot tear
        // the ring.
        if systemNextFrame == 0 || abs(stampedFrame - systemNextFrame) > 480 {
            systemNextFrame = stampedFrame
        }
        let frames = samples.count / Self.channelCount
        for frame in 0..<frames {
            let ringIndex = Int((systemNextFrame + Int64(frame)) % Int64(ringFrames)) * Self.channelCount
            ring[ringIndex] = samples[frame * Self.channelCount]
            ring[ringIndex + 1] = samples[frame * Self.channelCount + 1]
        }
        systemNextFrame += Int64(frames)
        systemHighWater = max(systemHighWater, systemNextFrame)
        flushPending(force: false)
    }

    private func flushPending(force: Bool) {
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        while let entry = pending.first {
            let startFrame = Int64((entry.presentationTime.seconds * Self.sampleRate).rounded())
            let endFrame = startFrame + Int64(entry.samples.count / Self.channelCount)
            let systemArrived = systemHighWater >= endFrame
            let waitedLongEnough = now - entry.presentationTime.seconds > jitterBudget
            guard force || systemArrived || waitedLongEnough else { return }
            pending.removeFirst()
            emit(samples: mixed(entry.samples, fromFrame: startFrame), at: entry.presentationTime)
        }
    }

    private func mixed(_ microphone: [Float], fromFrame startFrame: Int64) -> [Float] {
        var output = microphone
        let frames = microphone.count / Self.channelCount
        let oldestValid = systemHighWater - Int64(ringFrames)
        for frame in 0..<frames {
            let absolute = startFrame + Int64(frame)
            var left: Float = 0
            var right: Float = 0
            if absolute >= oldestValid && absolute < systemHighWater {
                let ringIndex = Int(absolute % Int64(ringFrames)) * Self.channelCount
                left = ring[ringIndex]
                right = ring[ringIndex + 1]
            }
            let index = frame * Self.channelCount
            output[index] = Self.limited(microphone[index] * microphoneGain + left * systemGain)
            output[index + 1] = Self.limited(microphone[index + 1] * microphoneGain + right * systemGain)
        }
        return output
    }

    private func scaled(_ samples: [Float], by gain: Float) -> [Float] {
        guard gain != 1 else { return samples }
        return samples.map { Self.limited($0 * gain) }
    }

    /// Soft limiter: transparent below the knee, then a smooth squeeze toward
    /// full scale. Two sources summed can exceed 0 dBFS; a hard clip there is
    /// the crackle everyone has heard in screen recordings with music.
    static func limited(_ sample: Float) -> Float {
        let knee: Float = 0.85
        let magnitude = abs(sample)
        guard magnitude > knee else { return sample }
        let squeezed = knee + (1 - knee) * tanhf((magnitude - knee) / (1 - knee))
        return sample < 0 ? -squeezed : squeezed
    }

    /// Converts any capture buffer to the canonical interleaved float format,
    /// rebuilding the converter when the source format changes (a different
    /// microphone between takes). Sample-rate conversion keeps state across
    /// buffers, which is why each source owns a persistent converter.
    private func convertToCanonical(
        _ sampleBuffer: CMSampleBuffer,
        converter: inout AVAudioConverter?,
        sourceFormat: inout AVAudioFormat?
    ) -> [Float]? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let inputFormat = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat?
        else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames)
        else { return nil }
        inputBuffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: inputBuffer.mutableAudioBufferList
        ) == noErr else { return nil }

        // Already canonical — the system tap's usual case — so copy straight
        // out. This is not only cheaper: AVAudioConverter keeps internal state
        // between calls even for identity conversions, and frames it holds
        // back from one buffer surface prepended to the next, shifting the
        // output against its timestamp.
        if inputFormat.sampleRate == Self.sampleRate,
           inputFormat.channelCount == AVAudioChannelCount(Self.channelCount),
           inputFormat.commonFormat == .pcmFormatFloat32,
           inputFormat.isInterleaved,
           let data = inputBuffer.audioBufferList.pointee.mBuffers.mData {
            let count = Int(frames) * Self.channelCount
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        }

        if converter == nil || sourceFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: canonicalFormat)
            sourceFormat = inputFormat
        }
        guard let converter else { return nil }

        let ratio = Self.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 64
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: capacity) else {
            return nil
        }
        var handedOver = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, statusPointer in
            if handedOver {
                statusPointer.pointee = .noDataNow
                return nil
            }
            handedOver = true
            statusPointer.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, outputBuffer.frameLength > 0,
              let data = outputBuffer.audioBufferList.pointee.mBuffers.mData
        else { return nil }
        let count = Int(outputBuffer.frameLength) * Self.channelCount
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
    }

    private func emit(samples: [Float], at presentationTime: CMTime) {
        guard let canonicalDescription, !samples.isEmpty else { return }
        let frames = samples.count / Self.channelCount
        let byteCount = samples.count * MemoryLayout<Float>.size

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
        ) == kCMBlockBufferNoErr, let blockBuffer else { return }
        let copied = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copied == kCMBlockBufferNoErr else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(Self.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = Self.channelCount * MemoryLayout<Float>.size
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: canonicalDescription,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }
        onMixedBuffer?(sampleBuffer)
    }
}
