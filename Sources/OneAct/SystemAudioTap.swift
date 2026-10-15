import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation

/// Captures the system audio mix through a Core Audio process tap.
///
/// This replaces ScreenCaptureKit as the system-audio source because SCK only
/// delivers audio for display-level shares — window shares get silent buffers,
/// and the System Audio toggle gated on "what happens to be shared" made a
/// sound feature depend on a picture choice. A process tap comes straight from
/// the audio subsystem: it works during window shares, display shares, or no
/// share at all.
///
/// The trade is a one-time "System Audio Recording Only" permission (the
/// tap's own prompt, in the same Settings pane as screen recording). OneAct's
/// own process is excluded from the tap, so the app can never feed itself
/// back into a take.
final class SystemAudioTap {
    /// Tapped audio as sample buffers on an internal queue, stamped on the
    /// host clock — the same clock the capture pipelines use, which is what
    /// lets the mixer line these samples up against the microphone.
    var onAudioSample: ((CMSampleBuffer) -> Void)?
    /// Fired once per failed start, with the OSStatus that killed it. The
    /// usual cause is a denied permission, which macOS never re-prompts for.
    var onStartFailure: ((OSStatus) -> Void)?

    private let queue = DispatchQueue(label: "oneact.system-audio-tap", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var formatDescription: CMAudioFormatDescription?
    private var bytesPerFrame = 0
    private(set) var isRunning = false

    func start() {
        queue.async { [self] in
            guard !isRunning else { return }
            let status = startOnQueue()
            if status != noErr {
                stopOnQueue()
                DispatchQueue.main.async { self.onStartFailure?(status) }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            stopOnQueue()
        }
    }

    private func startOnQueue() -> OSStatus {
        // Exclude our own process: translate this pid to its audio object.
        var ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        var ownProcessObject = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var objectSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let translateStatus = withUnsafeMutableBytes(of: &ownPID) { pidBytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(pidBytes.count),
                pidBytes.baseAddress,
                &objectSize,
                &ownProcessObject
            )
        }

        let description: CATapDescription
        if translateStatus == noErr, ownProcessObject != kAudioObjectUnknown {
            description = CATapDescription(
                stereoGlobalTapButExcludeProcesses: [ownProcessObject]
            )
        } else {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        // Private: no other process can see or attach to this tap.
        description.isPrivate = true
        description.muteBehavior = .unmuted

        // This is the call that prompts for the System Audio Recording
        // permission the first time, and fails outright on a standing denial.
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr else { return tapStatus }
        tapID = newTapID

        var streamDescription = AudioStreamBasicDescription()
        var streamSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let formatStatus = AudioObjectGetPropertyData(
            tapID, &formatAddress, 0, nil, &streamSize, &streamDescription
        )
        guard formatStatus == noErr, streamDescription.mBytesPerFrame > 0 else {
            return formatStatus == noErr ? kAudioHardwareUnspecifiedError : formatStatus
        }
        bytesPerFrame = Int(streamDescription.mBytesPerFrame)
        var newFormat: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &newFormat
        ) == noErr, let newFormat else { return kAudioHardwareUnspecifiedError }
        formatDescription = newFormat

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "OneAct System Audio",
            kAudioAggregateDeviceUIDKey as String: "com.oneact.system-audio." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: description.uuid.uuidString]
            ]
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newAggregateID
        )
        guard aggregateStatus == noErr else { return aggregateStatus }
        aggregateID = newAggregateID

        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, queue) {
            [weak self] _, inputData, inputTime, _, _ in
            self?.deliver(inputData, at: inputTime)
        }
        guard procStatus == noErr, let newProcID else { return procStatus }
        ioProcID = newProcID

        let startStatus = AudioDeviceStart(aggregateID, newProcID)
        guard startStatus == noErr else { return startStatus }
        isRunning = true
        return noErr
    }

    private func stopOnQueue() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        isRunning = false
    }

    private func deliver(
        _ bufferList: UnsafePointer<AudioBufferList>,
        at timestamp: UnsafePointer<AudioTimeStamp>
    ) {
        guard let formatDescription, bytesPerFrame > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )
        guard let first = buffers.first, first.mDataByteSize > 0 else { return }
        let frames = Int(first.mDataByteSize) / bytesPerFrame
        guard frames > 0 else { return }

        // The tap stamps buffers on the host clock; converting the units gives
        // the same timeline the camera and microphone already live on.
        let presentationTime = CMTime(
            seconds: CMClockMakeHostTimeFromSystemUnits(timestamp.pointee.mHostTime).seconds,
            preferredTimescale: 1_000_000_000
        )

        var timing = CMSampleTimingInfo(
            duration: CMTime(
                value: 1,
                timescale: CMTimeScale(CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee.mSampleRate ?? 48_000)
            ),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: bufferList
        ) == noErr else { return }
        onAudioSample?(sampleBuffer)
    }
}
