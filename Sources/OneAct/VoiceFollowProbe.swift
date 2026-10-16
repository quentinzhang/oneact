import AVFoundation
import Speech

/// Command-line checks for Follow voice that need no microphone.
///
/// `--speech-report` prints the speech-recognition permission and, for each
/// language Follow voice supports, whether this Mac can recognize it on
/// device. It never shows a permission prompt.
///
/// `--voice-follow-probe` drives the real recognizer with synthesized speech
/// (the aligner test's scripts, read by the system voice) through the same
/// sample-buffer path the microphone uses, and reports where the aligner
/// ends up. It needs Speech Recognition permission; with
/// `--request-permission` it asks for it, otherwise it only says so. Run it
/// inside the bundle so the permission belongs to OneAct:
/// `open -W --stdout /dev/stdout build/OneAct.app --args --voice-follow-probe`
@MainActor
enum VoiceFollowProbe {
    static func speechReport() -> Int32 {
        print("SPEECH_REPORT authorization=\(describe(OnDeviceTranscriber.authorizationStatus)) sandboxed=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)")
        for language in ScriptLanguage.allCases {
            let recognizer = SFSpeechRecognizer(locale: language.locale)
            print("SPEECH_LANGUAGE \(language.rawValue) recognizer=\(recognizer != nil) on_device=\(recognizer?.supportsOnDeviceRecognition ?? false) available=\(recognizer?.isAvailable ?? false)")
        }
        return 0
    }

    static func run(requestPermission: Bool) {
        let status = OnDeviceTranscriber.authorizationStatus
        if status == .notDetermined, requestPermission {
            OnDeviceTranscriber.requestAuthorization { _ in run(requestPermission: false) }
            return
        }
        guard status == .authorized else {
            print("VOICE_PROBE_SKIPPED authorization=\(describe(status)) · rerun with --request-permission, or allow OneAct in Privacy & Security → Speech Recognition")
            Darwin.exit(2)
        }
        let fixtures = [ScriptAlignerSelfTest.Fixture.chinese, ScriptAlignerSelfTest.Fixture.english]
        probe(fixtures[...], failures: 0)
    }

    private static func probe(_ remaining: ArraySlice<ScriptAlignerSelfTest.Fixture>, failures: Int) {
        guard let fixture = remaining.first else {
            print(failures == 0 ? "VOICE_PROBE_OK" : "VOICE_PROBE_FAILED cases=\(failures)")
            Darwin.exit(failures == 0 ? 0 : 1)
        }
        let session = ProbeSession(fixture: fixture)
        session.run { passed in
            probe(remaining.dropFirst(), failures: failures + (passed ? 0 : 1))
        }
    }

    private static func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not_determined"
        @unknown default: "unknown"
        }
    }
}

/// One script read aloud by the system voice into the recognizer.
@MainActor
private final class ProbeSession {
    let fixture: ScriptAlignerSelfTest.Fixture
    private let transcriber = OnDeviceTranscriber()
    private let aligner: ScriptAligner
    private let synthesizer = AVSpeechSynthesizer()
    private var lastText = ""
    private var updates = 0
    private var keepAlive: ProbeSession?

    init(fixture: ScriptAlignerSelfTest.Fixture) {
        self.fixture = fixture
        aligner = ScriptAligner(script: fixture.script, language: fixture.language)
    }

    func run(completion: @escaping (Bool) -> Void) {
        keepAlive = self
        transcriber.onUpdate = { [weak self] update in
            guard let self else { return }
            self.updates += 1
            self.lastText = update.text
            self.aligner.ingest(streamID: update.streamID, text: update.text)
        }
        transcriber.onProblem = { problem in
            print("VOICE_PROBE \(self.fixture.name) problem=\(problem.message)")
        }
        if let problem = transcriber.start(
            locale: fixture.language.locale,
            contextualStrings: SpeechText.contextualPhrases(in: fixture.script, language: fixture.language)
        ) {
            print("VOICE_PROBE \(fixture.name) unavailable: \(problem.message)")
            keepAlive = nil
            completion(false)
            return
        }

        // Synthesize the whole script, then feed it at twice real time as
        // capture-style sample buffers on a background queue, the way the
        // capture queue delivers the microphone.
        let utterance = AVSpeechUtterance(string: fixture.script.replacingOccurrences(of: "\n", with: " "))
        utterance.voice = AVSpeechSynthesisVoice(language: fixture.language.rawValue)
        var buffers: [AVAudioPCMBuffer] = []
        synthesizer.write(utterance) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength > 0 {
                buffers.append(pcm)
            } else {
                Task { @MainActor in self?.feed(buffers, completion: completion) }
            }
        }
    }

    private func feed(_ buffers: [AVAudioPCMBuffer], completion: @escaping (Bool) -> Void) {
        let seconds = buffers.reduce(0.0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
        print("VOICE_PROBE \(fixture.name) synthesized=\(String(format: "%.1f", seconds))s buffers=\(buffers.count) voice=\(AVSpeechSynthesisVoice(language: fixture.language.rawValue)?.identifier ?? "none")")
        let transcriber = self.transcriber
        DispatchQueue.global(qos: .userInitiated).async {
            var hostTime = CMClockGetTime(CMClockGetHostTimeClock())
            for buffer in buffers {
                if let sample = buffer.makeSampleBuffer(presentationTime: hostTime) {
                    transcriber.append(sample)
                }
                let duration = Double(buffer.frameLength) / buffer.format.sampleRate
                hostTime = CMTimeAdd(hostTime, CMTime(seconds: duration, preferredTimescale: 48_000))
                Thread.sleep(forTimeInterval: duration / 2)
            }
            // Trailing silence lets the recognizer settle its last words.
            Thread.sleep(forTimeInterval: 3)
            DispatchQueue.main.async { self.finish(completion: completion) }
        }
    }

    private func finish(completion: @escaping (Bool) -> Void) {
        transcriber.stop()
        let total = aligner.tokens.count
        let passed = aligner.position >= total - max(fixture.endTolerance, total / 20)
        print("VOICE_PROBE \(fixture.name) end=\(aligner.position)/\(total) updates=\(updates) passed=\(passed)")
        print("VOICE_PROBE \(fixture.name) heard_tail=\(String(lastText.suffix(80)))")
        keepAlive = nil
        completion(passed)
    }
}

extension AVAudioPCMBuffer {
    /// Wraps the buffer the way capture delivers audio, for the probe and the
    /// offline conversion test.
    func makeSampleBuffer(presentationTime: CMTime) -> CMSampleBuffer? {
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        ) == noErr, let description else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleCount: CMItemCount(frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sample,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: audioBufferList
        ) == noErr else { return nil }
        return sample
    }
}
