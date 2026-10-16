import AVFoundation
import Speech

/// A word the recognizer heard, placed on the host clock — the clock capture
/// stamps every sample with — so a consumer can line it up with the preview
/// or, through the pause clock, with the recording.
struct TranscribedWord: Equatable {
    let text: String
    let start: TimeInterval
    let duration: TimeInterval
}

/// The recognizer's current belief about one stream of speech.
struct TranscriptUpdate {
    /// One per recognition task. Long sessions roll over into new tasks, and a
    /// new stream starts empty; ids only increase.
    let streamID: Int
    /// Everything heard in this stream so far. Partial results are revised in
    /// place, so an update replaces the previous one for the same stream.
    let text: String
    let isFinal: Bool
    let words: [TranscribedWord]
}

/// Why on-device recognition cannot run, in words the presenter can act on.
enum TranscriberProblem: Equatable {
    case notDetermined
    case denied
    case restricted
    case unsupportedLanguage(String)
    case onDeviceModelMissing(String)
    case unavailable
    case failed(String)

    var message: String {
        switch self {
        case .notDetermined:
            "Speech recognition permission has not been granted yet."
        case .denied:
            "Speech recognition is off for OneAct. Turn it on in System Settings → Privacy & Security → Speech Recognition."
        case .restricted:
            "Speech recognition is restricted on this Mac."
        case .unsupportedLanguage(let language):
            "This Mac cannot recognize \(language)."
        case .onDeviceModelMissing(let language):
            "On-device recognition for \(language) is not installed. Turn on Dictation for \(language) in System Settings → Keyboard, then try again. OneAct never sends audio off this Mac."
        case .unavailable:
            "Speech recognition is unavailable right now. Try again in a moment."
        case .failed(let reason):
            "Speech recognition stopped: \(reason)"
        }
    }
}

/// Live, on-device speech recognition of microphone sample buffers.
///
/// Deliberately small and unaware of what the text is for: start for a
/// locale, feed audio, receive revisable partial and final results with
/// timestamps, stop. The teleprompter aligns the text to a script; another
/// consumer could caption it. Audio never leaves the Mac —
/// `requiresOnDeviceRecognition` is always set, and a language without an
/// on-device model is reported as a problem rather than sent to a server.
///
/// Recognition runs in streams: one `SFSpeechRecognitionTask` at a time,
/// rolled over to a fresh one after about a minute of audio (at a quiet
/// moment when possible), and restarted whenever the recognizer ends one on
/// its own. Results and problems arrive on the main queue.
///
/// `append` may be called from any thread (in practice the capture queue);
/// everything else is main-thread only.
final class OnDeviceTranscriber: @unchecked Sendable {
    var onUpdate: ((TranscriptUpdate) -> Void)?
    /// Recognition stopped and will not restart on its own.
    var onProblem: ((TranscriberProblem) -> Void)?

    /// Roll over after this much audio once speech pauses, and at the
    /// second limit regardless.
    private let softStreamLimit: TimeInterval = 45
    private let hardStreamLimit: TimeInterval = 58
    private let quietBeforeRollover: TimeInterval = 0.8

    // Shared with the audio thread, under `lock`.
    private let lock = NSLock()
    private var running = false
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var streamID = 0
    private var streamAudioSeconds: TimeInterval = 0
    private var streamStartTimes: [Int: TimeInterval] = [:]
    private var rolloverRequested = false
    private var lastAudioArrival: TimeInterval?
    private var lastResultArrival: TimeInterval = 0
    private var converter = RecognitionAudioConverter()

    // Main thread only.
    private var recognizer: SFSpeechRecognizer?
    private var tasks: [Int: SFSpeechRecognitionTask] = [:]
    private var contextualStrings: [String] = []
    private var recentFailures: [TimeInterval] = []

    static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    /// Shows the system prompt the first time; later calls answer at once.
    static func requestAuthorization(_ completion: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status) }
        }
    }

    /// Nil when recognition can start for `locale` right now.
    static func problem(for locale: Locale) -> TranscriberProblem? {
        switch authorizationStatus {
        case .authorized: break
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
        let language = displayName(of: locale)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return .unsupportedLanguage(language)
        }
        guard recognizer.supportsOnDeviceRecognition else { return .onDeviceModelMissing(language) }
        guard recognizer.isAvailable else { return .unavailable }
        return nil
    }

    static func displayName(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Host-clock seconds since the last audio buffer arrived, or nil when
    /// none has since `start`.
    var secondsSinceAudio: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return lastAudioArrival.map { Self.hostNow() - $0 }
    }

    /// Starts recognizing; returns the problem instead when it cannot.
    /// `contextualStrings` are phrases the speech is likely to contain.
    @discardableResult
    func start(locale: Locale, contextualStrings: [String]) -> TranscriberProblem? {
        dispatchPrecondition(condition: .onQueue(.main))
        stop()
        if let problem = Self.problem(for: locale) { return problem }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return .unsupportedLanguage(Self.displayName(of: locale))
        }
        recognizer.queue = .main
        self.recognizer = recognizer
        self.contextualStrings = Array(contextualStrings.prefix(100))
        recentFailures = []
        lock.lock()
        running = true
        lastAudioArrival = nil
        lastResultArrival = Self.hostNow()
        lock.unlock()
        beginStream()
        return nil
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock()
        running = false
        let finished = request
        request = nil
        converter = RecognitionAudioConverter()
        streamStartTimes = [:]
        lock.unlock()
        finished?.endAudio()
        for task in tasks.values { task.cancel() }
        tasks = [:]
        recognizer = nil
    }

    /// Feeds microphone audio. Cheap to call while stopped.
    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard running, let request else { return }
        let now = Self.hostNow()
        lastAudioArrival = now
        guard let buffer = converter.convert(sampleBuffer) else { return }
        if streamStartTimes[streamID] == nil {
            let stamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            streamStartTimes[streamID] = stamp.isValid ? stamp.seconds : now
        }
        request.append(buffer)
        streamAudioSeconds += Double(buffer.frameLength) / buffer.format.sampleRate

        let quiet = now - lastResultArrival >= quietBeforeRollover
        if !rolloverRequested,
           streamAudioSeconds >= hardStreamLimit
            || (streamAudioSeconds >= softStreamLimit && quiet) {
            rolloverRequested = true
            DispatchQueue.main.async { [weak self] in self?.rollOver() }
        }
    }

    // MARK: - Streams

    private func rollOver() {
        guard isRunning else { return }
        beginStream()
    }

    /// Opens a new recognition task and hands it the audio from here on. The
    /// previous stream is told its audio has ended, so it still delivers its
    /// final result for the words already heard.
    private func beginStream() {
        guard let recognizer else { return }
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.requiresOnDeviceRecognition = true
        newRequest.shouldReportPartialResults = true
        newRequest.taskHint = .dictation
        newRequest.addsPunctuation = false
        newRequest.contextualStrings = contextualStrings

        lock.lock()
        let previous = request
        streamID += 1
        let id = streamID
        request = newRequest
        streamAudioSeconds = 0
        rolloverRequested = false
        lock.unlock()
        previous?.endAudio()

        tasks[id] = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            self?.handle(result: result, error: error, stream: id)
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, stream id: Int) {
        guard isRunning else { return }
        if let result {
            lock.lock()
            lastResultArrival = Self.hostNow()
            let origin = streamStartTimes[id] ?? lastResultArrival
            lock.unlock()
            let transcription = result.bestTranscription
            let words = transcription.segments.map {
                TranscribedWord(text: $0.substring, start: origin + $0.timestamp, duration: $0.duration)
            }
            if !transcription.formattedString.isEmpty { recentFailures = [] }
            onUpdate?(TranscriptUpdate(
                streamID: id,
                text: transcription.formattedString,
                isFinal: result.isFinal,
                words: words
            ))
        }
        guard result?.isFinal == true || error != nil else { return }
        tasks[id] = nil
        lock.lock()
        streamStartTimes[id] = nil
        let isCurrent = id == streamID
        lock.unlock()
        guard isCurrent else { return }

        // The recognizer ended the current stream on its own — end of speech,
        // a time limit, "no speech detected", a hiccup in the speech service.
        // Carry on in a fresh stream, unless it keeps failing.
        if let error {
            let now = Self.hostNow()
            recentFailures = recentFailures.filter { now - $0 < 15 } + [now]
            if recentFailures.count >= 5 {
                stop()
                onProblem?(.failed(error.localizedDescription))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.isRunning, self.currentStreamID == id else { return }
                self.beginStream()
            }
        } else {
            beginStream()
        }
    }

    private var currentStreamID: Int {
        lock.lock()
        defer { lock.unlock() }
        return streamID
    }

    private static func hostNow() -> TimeInterval {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }
}

/// Turns capture buffers into what the recognizer prefers: 16 kHz mono
/// float. The converter is kept across buffers — it carries resampler state
/// from one to the next — and rebuilt only when the input format changes.
struct RecognitionAudioConverter {
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?

    mutating func convert(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames) else { return nil }
        input.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: input.mutableAudioBufferList
        ) == noErr else { return nil }
        let target = Self.format
        if inputFormat == target { return input }

        if converter == nil || converterInput != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: target)
            // A mono microphone often arrives as one live channel of a stereo
            // pair; mixing down keeps it audible instead of taking channel 1.
            converter?.downmix = true
            converterInput = inputFormat
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(frames) * target.sampleRate / inputFormat.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var handedOver = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if handedOver {
                inputStatus.pointee = .noDataNow
                return nil
            }
            handedOver = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
