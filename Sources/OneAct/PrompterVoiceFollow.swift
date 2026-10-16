import AppKit
import AVFoundation

/// Which language Follow voice listens for.
enum FollowVoiceLanguage: String, CaseIterable {
    case automatic
    case chinese
    case english

    var forced: ScriptLanguage? {
        switch self {
        case .automatic: nil
        case .chinese: .chinese
        case .english: .english
        }
    }
}

private enum FollowVoiceDefaults {
    static let language = "teleprompter.followVoiceLanguage"
}

/// Follow voice: the teleprompter keeps pace with the presenter's voice.
///
/// Glue between the on-device recognizer and the script aligner, plus the
/// presenter-facing status. It listens only while the teleprompter is
/// rolling, through the microphone the recording uses: the capture session
/// already delivers its samples whenever the preview runs, so no second
/// capture session is ever opened.
@MainActor
final class PrompterVoiceFollow {
    enum Status: Equatable {
        /// Not listening.
        case idle
        /// Waiting for the permission prompt or the recognizer.
        case starting
        case listening
        /// Hearing speech that is not in the script; the position holds.
        case offScript
        /// Listening, but no audio is reaching it.
        case noAudio
        case unavailable(String)

        var label: String {
            switch self {
            case .idle: "Ready"
            case .starting: "Starting…"
            case .listening: "Listening"
            case .offScript: "Off script"
            case .noAudio: "No mic audio"
            case .unavailable: "Unavailable"
            }
        }
    }

    var onStatusChange: ((Status) -> Void)?
    /// The spoken position moved.
    var onProgress: (() -> Void)?
    /// Why the microphone cannot be listened to right now, if anything. Set
    /// by whoever owns the capture session.
    var microphoneProblem: (() -> String?)?

    private(set) var status: Status = .idle {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    /// Listening is wanted: between `start` and `stop`, including while the
    /// permission prompt is up.
    private(set) var isActive = false

    var languageChoice: FollowVoiceLanguage {
        didSet {
            guard languageChoice != oldValue else { return }
            UserDefaults.standard.set(languageChoice.rawValue, forKey: FollowVoiceDefaults.language)
            rebuildAligner(keepingPosition: true)
            if isActive, transcriber.isRunning { startRecognition() }
        }
    }

    /// The language actually listened for.
    var language: ScriptLanguage { aligner.language }

    private let transcriber = OnDeviceTranscriber()
    private var aligner = ScriptAligner(script: "")
    private var script = ""
    private var watchdog: Timer?
    private var startedAt: TimeInterval = 0
    private var offScriptSince: TimeInterval?

    init() {
        let stored = UserDefaults.standard.string(forKey: FollowVoiceDefaults.language)
        languageChoice = stored.flatMap(FollowVoiceLanguage.init(rawValue:)) ?? .automatic
        transcriber.onUpdate = { [weak self] update in self?.handle(update) }
        transcriber.onProblem = { [weak self] problem in self?.fail(problem.message) }
    }

    /// Called from the capture queue for every microphone buffer.
    nonisolated func appendMicrophone(_ sampleBuffer: CMSampleBuffer) {
        transcriber.append(sampleBuffer)
    }

    var spokenCharacterEnd: Int { aligner.spokenCharacterEnd }
    var nextCharacterLocation: Int { aligner.nextCharacterLocation }

    func setScript(_ text: String) {
        guard text != script else { return }
        script = text
        rebuildAligner(keepingPosition: false)
        if isActive, transcriber.isRunning { startRecognition() }
    }

    private func rebuildAligner(keepingPosition: Bool) {
        let offset = aligner.nextCharacterLocation
        aligner = ScriptAligner(script: script, language: languageChoice.forced)
        if keepingPosition { aligner.reposition(toCharacterOffset: offset) }
    }

    /// The presenter moved the script by hand: what is on the reading line
    /// now is where they are.
    func reposition(toCharacterOffset offset: Int) {
        aligner.reposition(toCharacterOffset: offset)
        onProgress?()
    }

    func resetToStart() {
        aligner.reset()
        onProgress?()
    }

    /// Asks for speech recognition permission the moment the presenter turns
    /// Follow voice on, never earlier, and reports anything that stands in
    /// the way.
    func prepare() {
        if OnDeviceTranscriber.authorizationStatus == .notDetermined {
            status = .starting
            OnDeviceTranscriber.requestAuthorization { [weak self] _ in
                guard let self else { return }
                if self.isActive {
                    self.startRecognition()
                } else {
                    self.status = self.readinessProblem().map(Status.unavailable) ?? .idle
                }
            }
            return
        }
        status = readinessProblem().map(Status.unavailable) ?? .idle
    }

    /// Starts listening. Returns false when following cannot work right now;
    /// `status` says why. A pending permission prompt counts as starting.
    @discardableResult
    func start() -> Bool {
        guard !isActive else { return true }
        isActive = true
        if OnDeviceTranscriber.authorizationStatus == .notDetermined {
            prepare()
            return true
        }
        return startRecognition()
    }

    func stop() {
        isActive = false
        watchdog?.invalidate()
        watchdog = nil
        transcriber.stop()
        offScriptSince = nil
        if case .unavailable = status { return }
        status = .idle
    }

    private func readinessProblem() -> String? {
        if let problem = microphoneProblem?() { return problem }
        return OnDeviceTranscriber.problem(for: aligner.language.locale)?.message
    }

    @discardableResult
    private func startRecognition() -> Bool {
        if let problem = readinessProblem() {
            fail(problem)
            return false
        }
        if let problem = transcriber.start(
            locale: aligner.language.locale,
            contextualStrings: SpeechText.contextualPhrases(in: script, language: aligner.language)
        ) {
            fail(problem.message)
            return false
        }
        aligner.clearTranscript()
        startedAt = ProcessInfo.processInfo.systemUptime
        offScriptSince = nil
        status = .listening
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHealth() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        return true
    }

    private func fail(_ message: String) {
        isActive = false
        watchdog?.invalidate()
        watchdog = nil
        transcriber.stop()
        status = .unavailable(message)
    }

    private func handle(_ update: TranscriptUpdate) {
        guard isActive else { return }
        let before = aligner.position
        let step = aligner.ingest(streamID: update.streamID, text: update.text)
        switch step.outcome {
        case .advanced, .movedBack, .held:
            offScriptSince = nil
        case .offScript:
            if offScriptSince == nil { offScriptSince = ProcessInfo.processInfo.systemUptime }
        }
        if aligner.position != before { onProgress?() }
        checkHealth()
    }

    /// Off-script needs to last a moment before it is shown — a single
    /// misheard partial is not an ad-lib — and silence from the microphone
    /// is reported after two seconds.
    private func checkHealth() {
        guard isActive, transcriber.isRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let silentFor = transcriber.secondsSinceAudio ?? (now - startedAt)
        if silentFor > 2 {
            status = .noAudio
        } else if let since = offScriptSince, now - since > 1.2 {
            status = .offScript
        } else {
            status = .listening
        }
    }

    // MARK: - Diagnostics

    /// Places the spoken position without any audio, for the layout report.
    func setSpokenPositionForDiagnostics(characterOffset: Int) {
        aligner.reposition(toCharacterOffset: characterOffset)
        onProgress?()
    }

    var spokenTokenCount: Int { aligner.position }

    /// Feeds recognizer text as if it had been heard, for the layout report.
    func ingestForDiagnostics(streamID: Int, text: String) {
        let before = aligner.position
        aligner.ingest(streamID: streamID, text: text)
        if aligner.position != before { onProgress?() }
    }
}

/// The Follow voice controls in the teleprompter's bar: a toggle, and — in
/// place of the speed slider while it is on — the recognition language and
/// what the follower is doing.
@MainActor
final class PrompterFollowControls: NSObject {
    let toggle: NSButton
    let panel: NSStackView
    var onToggle: ((Bool) -> Void)?
    var onLanguageChange: ((FollowVoiceLanguage) -> Void)?

    private let languageButton: NSButton
    private let statusLabel: NSTextField
    private var tint: NSColor = .white
    private var isOn = false
    private var languageTitle = "EN"
    private var currentChoice: FollowVoiceLanguage = .automatic

    override init() {
        toggle = NSButton(title: "", target: nil, action: nil)
        languageButton = NSButton(title: "", target: nil, action: nil)
        statusLabel = NSTextField(labelWithString: "")
        panel = NSStackView()
        super.init()

        toggle.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Follow voice")
        toggle.setButtonType(.toggle)
        toggle.isBordered = false
        toggle.bezelStyle = .regularSquare
        toggle.toolTip = "Follow voice · the script scrolls as you read it aloud. Recognition runs on this Mac only."
        toggle.target = self
        toggle.action = #selector(toggleClicked)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.widthAnchor.constraint(equalToConstant: 22).isActive = true
        toggle.heightAnchor.constraint(equalToConstant: 20).isActive = true

        languageButton.isBordered = false
        languageButton.bezelStyle = .regularSquare
        languageButton.target = self
        languageButton.action = #selector(showLanguageMenu)
        languageButton.setContentHuggingPriority(.required, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 110).isActive = true

        panel.setViews([languageButton, statusLabel], in: .leading)
        panel.orientation = .horizontal
        panel.alignment = .centerY
        panel.spacing = 6
    }

    func setOn(_ on: Bool) {
        isOn = on
        toggle.state = on ? .on : .off
        panel.isHidden = !on
        applyTint(tint)
    }

    func applyTint(_ color: NSColor) {
        tint = color
        toggle.contentTintColor = isOn ? .controlAccentColor : color
        statusLabel.textColor = color.withAlphaComponent(0.7)
        renderLanguageTitle()
    }

    func update(status: PrompterVoiceFollow.Status) {
        statusLabel.stringValue = status.label
        if case .unavailable(let message) = status {
            statusLabel.toolTip = message
        } else {
            statusLabel.toolTip = nil
        }
    }

    func update(choice: FollowVoiceLanguage, resolved: ScriptLanguage) {
        currentChoice = choice
        languageTitle = resolved == .chinese ? "中文" : "EN"
        let name = resolved == .chinese ? "Chinese (Simplified)" : "English"
        languageButton.toolTip = choice == .automatic
            ? "Listening for \(name) · chosen from the script. Click to change."
            : "Listening for \(name). Click to change."
        renderLanguageTitle()
    }

    private func renderLanguageTitle() {
        languageButton.attributedTitle = NSAttributedString(
            string: languageTitle + " ▾",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: tint
            ]
        )
    }

    @objc private func toggleClicked() {
        onToggle?(toggle.state == .on)
    }

    @objc private func showLanguageMenu() {
        let menu = NSMenu()
        let items: [(String, FollowVoiceLanguage)] = [
            ("Automatic (from the script)", .automatic),
            ("Chinese (Simplified)", .chinese),
            ("English", .english)
        ]
        for (title, choice) in items {
            let item = NSMenuItem(title: title, action: #selector(languagePicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = choice == currentChoice ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: languageButton.bounds.height + 2), in: languageButton)
    }

    @objc private func languagePicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = FollowVoiceLanguage(rawValue: raw) else { return }
        currentChoice = choice
        onLanguageChange?(choice)
    }
}

/// Moves the script toward the spoken position: a critically damped spring,
/// clamped so it never passes its target, so it glides, settles without
/// overshoot, and stops dead when the target stops — which is what makes the
/// script wait when the presenter pauses.
struct PrompterFollowSpring {
    private(set) var offset: CGFloat = 0
    private var velocity: CGFloat = 0
    /// Response rate, 1/s: about half a second to cover most of a step.
    var stiffness: CGFloat = 4.5
    var maximumSpeed: CGFloat = 900

    mutating func reset(to value: CGFloat) {
        offset = value
        velocity = 0
    }

    /// Advances by `dt` seconds toward `target`, using the exact solution of
    /// the critically damped spring so any frame interval stays stable.
    mutating func step(toward target: CGFloat, dt: Double) -> CGFloat {
        let t = CGFloat(max(0, dt))
        let displacement = offset - target
        if abs(displacement) < 0.3, abs(velocity) < 2 {
            offset = target
            velocity = 0
            return offset
        }
        let w = stiffness
        let decay = exp(-w * t)
        let c = velocity + w * displacement
        offset = target + (displacement + c * t) * decay
        velocity = (velocity - w * c * t) * decay
        velocity = min(max(velocity, -maximumSpeed), maximumSpeed)
        // A critically damped spring still overshoots once when it arrives
        // with speed — and a target that advances word by word builds speed.
        // Overshooting would scroll the script back a little after every
        // phrase, so it stops on the target instead.
        if (displacement < 0 && offset > target) || (displacement > 0 && offset < target) {
            offset = target
            velocity = 0
        }
        return offset
    }
}

/// Drives the teleprompter's scroll view in Follow voice mode: the spoken
/// position goes to the reading line through the spring, what has been said
/// is dimmed, and a drag or scroll by hand re-anchors the follower to
/// whatever line the presenter put on the reading line.
@MainActor
final class PrompterFollowScroller {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private var spring = PrompterFollowSpring()
    /// Where this scroller last put the clip view. Anything else moving it is
    /// the presenter's hand.
    private var lastApplied: CGFloat?
    private var lastTick: TimeInterval?
    /// After a manual move the spring waits, so it does not fight the hand.
    private var manualUntil: TimeInterval = 0
    private var cachedTarget: (location: Int, offset: CGFloat)?
    private var dimmedUpTo = -1
    var dimColor: NSColor = .gray {
        didSet { dimmedUpTo = -1 }
    }
    /// Where the spoken line sits, as a fraction of the visible height from
    /// the top: a little above the middle of the fade's bright band, leaving
    /// more of what comes next in view than what was just said.
    private let readingLine: CGFloat = 0.42

    func attach(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
    }

    private var currentOffset: CGFloat { scrollView?.contentView.bounds.origin.y ?? 0 }

    private var maximumOffset: CGFloat {
        guard let textView, let scrollView else { return 0 }
        return max(0, textView.frame.height - scrollView.contentSize.height)
    }

    /// Starts following from wherever the script sits now. If it is where
    /// following left it, the spoken position stands; if the presenter (or
    /// timed scrolling) moved it, the line on the reading line is the new
    /// starting point.
    func begin(with follow: PrompterVoiceFollow) {
        let actual = currentOffset
        let movedSinceLastTime = lastApplied.map { abs(actual - $0) > 1 } ?? (actual > 1)
        if movedSinceLastTime { reanchor(follow, at: actual) }
        spring.reset(to: actual)
        lastApplied = actual
        lastTick = nil
        manualUntil = 0
        refreshDimming(follow)
    }

    /// One display frame. `now` is only passed by the layout report's
    /// simulation, which runs on its own clock.
    func tick(with follow: PrompterVoiceFollow, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let scrollView else { return }
        let dt = min(now - (lastTick ?? now), 0.25)
        lastTick = now

        let actual = currentOffset
        if let lastApplied, abs(actual - lastApplied) > 1 {
            manualUntil = now + 0.6
            spring.reset(to: actual)
            self.lastApplied = actual
            reanchor(follow, at: actual)
            return
        }
        guard now >= manualUntil, let target = target(for: follow) else { return }
        let next = spring.step(toward: min(max(0, target), maximumOffset), dt: dt)
        if abs(next - actual) >= 0.25 {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: next))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        // Read back: the clip view may round to the pixel grid.
        lastApplied = currentOffset
    }

    /// The spoken position moved.
    func progressed(_ follow: PrompterVoiceFollow) {
        refreshDimming(follow)
    }

    /// The text or its layout changed (new script, font size, width).
    func layoutChanged() {
        cachedTarget = nil
        dimmedUpTo = -1
    }

    /// The script went back to the top.
    func reset() {
        spring.reset(to: 0)
        lastApplied = 0
        cachedTarget = nil
    }

    func clearDimming() {
        textView?.prompterDimText(upTo: 0, color: dimColor)
        dimmedUpTo = 0
    }

    /// Puts the spoken position on the reading line at once, for the layout
    /// report. Returns the offset applied.
    @discardableResult
    func snap(to follow: PrompterVoiceFollow) -> CGFloat {
        guard let scrollView, let target = target(for: follow) else { return 0 }
        let offset = min(max(0, target), maximumOffset)
        spring.reset(to: offset)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        lastApplied = currentOffset
        refreshDimming(follow)
        return offset
    }

    /// Converts between a clip-view offset and the text-container height
    /// that offset puts on the reading line.
    private var readingLineShift: CGFloat {
        guard let textView, let scrollView else { return 0 }
        return scrollView.contentSize.height * readingLine - textView.textContainerInset.height
    }

    private func reanchor(_ follow: PrompterVoiceFollow, at offset: CGFloat) {
        guard let character = textView?.prompterCharacterOffset(atLinePosition: offset + readingLineShift) else {
            return
        }
        follow.reposition(toCharacterOffset: character)
    }

    /// The offset that puts the next word on the reading line. The position
    /// is interpolated across its line, so the line's middle crosses the
    /// reading line halfway through it and the script glides word by word.
    func target(for follow: PrompterVoiceFollow) -> CGFloat? {
        let location = follow.nextCharacterLocation
        if let cachedTarget, cachedTarget.location == location { return cachedTarget.offset }
        guard let line = textView?.prompterLinePosition(forCharacterAt: location) else { return nil }
        let offset = line.top + line.height * line.fraction - readingLineShift
        cachedTarget = (location, offset)
        return offset
    }

    private func refreshDimming(_ follow: PrompterVoiceFollow) {
        let end = follow.spokenCharacterEnd
        guard end != dimmedUpTo else { return }
        textView?.prompterDimText(upTo: end, color: dimColor)
        dimmedUpTo = end
    }
}

/// Drives the follower through the real view hierarchy without audio, for
/// the layout report: the presenter reads most of the script a few
/// characters per update, stops, then drags the script back by hand. The
/// scroll must never step backwards while they read, must settle on the
/// spoken line and stay still once they stop, and must re-anchor to the line
/// they dragged to.
@MainActor
enum PrompterFollowSimulation {
    static let sampleScript = """
    大家好，欢迎来到这一期的节目。今天我们来聊一聊一镜到底的录制方式。

    所见即所得，预览里看到的就是最终保存的画面。没有时间线，也没有导出和二次剪辑。

    接下来我们一起来看看提词器是怎么跟上你的声音的。你停下来的时候，稿子也会停下来等你。
    """

    static func run(
        follow: PrompterVoiceFollow,
        scroller: PrompterFollowScroller,
        scrollView: NSScrollView,
        script: String
    ) -> String {
        let tokens = SpeechText.tokenize(script).tokens
        let separator = follow.language == .chinese ? "" : " "
        let spoken = tokens.count * 6 / 10
        var clock: TimeInterval = 10_000
        var offset: CGFloat { scrollView.contentView.bounds.origin.y }
        func run(frames: Int) {
            for _ in 0..<frames {
                clock += 1.0 / 60
                scroller.tick(with: follow, now: clock)
            }
        }

        // From the top, as after the teleprompter's ⤒ button.
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scroller.reset()
        follow.resetToStart()
        scroller.begin(with: follow)
        var heard = ""
        var backwardSteps = 0
        var previous = offset
        var index = 0
        while index < spoken {
            let next = min(spoken, index + 3)
            heard += tokens[index..<next].map(\.text).joined(separator: separator) + separator
            index = next
            follow.ingestForDiagnostics(streamID: 1, text: heard)
            for _ in 0..<15 {
                run(frames: 1)
                if offset < previous - 0.01 { backwardSteps += 1 }
                previous = offset
            }
        }
        let reached = follow.spokenTokenCount

        // The presenter stops talking: the script settles, then stays put.
        run(frames: 180)
        let settled = offset
        let target = scroller.target(for: follow) ?? -1
        let maximum = max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentSize.height)
        let onTarget = abs(settled - min(max(0, target), maximum)) < 1
        run(frames: 120)
        let still = offset == settled

        // A hand drags the script back two lines; following re-anchors there
        // instead of yanking it back.
        let before = follow.nextCharacterLocation
        let dragged = max(0, settled - 2 * 40)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: dragged))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        run(frames: 1)
        let after = follow.nextCharacterLocation
        run(frames: 120)
        let stayedNearDrag = abs(offset - dragged) < 60

        let passed = reached >= spoken - 3 && backwardSteps == 0 && onTarget && still
            && after < before && stayedNearDrag
        return "ok=\(passed) reached=\(reached)/\(spoken) backward_steps=\(backwardSteps) settled=\(Int(settled)) on_target=\(onTarget) still_after_speech=\(still) reanchored=\(before)->\(after) stayed_near_drag=\(stayedNearDrag)"
    }
}

extension NSTextView {
    /// The line holding the character at `offset`, in text-container
    /// coordinates, and how far along that line the character is (0…1).
    func prompterLinePosition(forCharacterAt offset: Int) -> (top: CGFloat, height: CGFloat, fraction: CGFloat)? {
        if let layout = textLayoutManager, let content = layout.textContentManager {
            let document = content.documentRange
            let length = content.offset(from: document.location, to: document.endLocation)
            let clamped = min(max(0, offset), length)
            guard let location = content.location(document.location, offsetBy: clamped) else { return nil }
            layout.ensureLayout(for: document)
            var fragment = layout.textLayoutFragment(for: location)
            if fragment == nil {
                // The end of the document: the last fragment holds it.
                layout.enumerateTextLayoutFragments(
                    from: document.endLocation,
                    options: [.reverse, .ensuresLayout]
                ) { candidate in
                    fragment = candidate
                    return false
                }
            }
            guard let fragment else { return nil }
            let elementStart = fragment.textElement?.elementRange?.location ?? fragment.rangeInElement.location
            let local = clamped - content.offset(from: document.location, to: elementStart)
            let lines = fragment.textLineFragments
            guard let line = lines.first(where: { local < NSMaxRange($0.characterRange) }) ?? lines.last else {
                return (fragment.layoutFragmentFrame.minY, fragment.layoutFragmentFrame.height, 0)
            }
            let range = line.characterRange
            let fraction = range.length > 0
                ? min(max(CGFloat(local - range.location) / CGFloat(range.length), 0), 1)
                : 0
            let bounds = line.typographicBounds
            return (fragment.layoutFragmentFrame.minY + bounds.minY, bounds.height, fraction)
        }
        // TextKit 1 only when the view already is; asking a TextKit 2 view
        // for its layout manager would switch it over.
        guard let layoutManager else { return nil }
        let length = layoutManager.numberOfGlyphs
        guard length > 0 else { return (0, 0, 0) }
        let glyph = min(layoutManager.glyphIndexForCharacter(at: max(0, offset)), length - 1)
        var lineRange = NSRange()
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
        let fraction = lineRange.length > 0
            ? CGFloat(glyph - lineRange.location) / CGFloat(lineRange.length)
            : 0
        return (rect.minY, rect.height, fraction)
    }

    /// The first character of the line at height `position` in the text
    /// container.
    func prompterCharacterOffset(atLinePosition position: CGFloat) -> Int? {
        if let layout = textLayoutManager, let content = layout.textContentManager {
            let document = content.documentRange
            layout.ensureLayout(for: document)
            var found: NSTextLayoutFragment?
            layout.enumerateTextLayoutFragments(from: document.location, options: [.ensuresLayout]) { fragment in
                found = fragment
                return fragment.layoutFragmentFrame.maxY < position
            }
            guard let fragment = found else { return nil }
            let elementStart = fragment.textElement?.elementRange?.location ?? fragment.rangeInElement.location
            let start = content.offset(from: document.location, to: elementStart)
            let localY = position - fragment.layoutFragmentFrame.minY
            let line = fragment.textLineFragments.last { $0.typographicBounds.minY <= localY }
                ?? fragment.textLineFragments.first
            return start + (line?.characterRange.location ?? 0)
        }
        guard let layoutManager, let container = textContainer else { return nil }
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 1, y: position), in: container)
        var lineRange = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
        return layoutManager.characterIndexForGlyph(at: lineRange.location)
    }

    /// Dims what has been said, as a drawing-time attribute: the text and its
    /// layout are untouched.
    func prompterDimText(upTo end: Int, color: NSColor) {
        if let layout = textLayoutManager, let content = layout.textContentManager {
            let document = content.documentRange
            layout.removeRenderingAttribute(.foregroundColor, for: document)
            if end > 0,
               let endLocation = content.location(document.location, offsetBy: end),
               let range = NSTextRange(location: document.location, end: endLocation) {
                layout.addRenderingAttribute(.foregroundColor, value: color, for: range)
            }
            needsDisplay = true
            return
        }
        guard let layoutManager else { return }
        let whole = NSRange(location: 0, length: (string as NSString).length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        if end > 0 {
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: color,
                forCharacterRange: NSRange(location: 0, length: min(end, whole.length))
            )
        }
    }
}
