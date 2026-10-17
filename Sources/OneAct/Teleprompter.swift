import AppKit

/// Reading settings that outlive a launch.
private enum TeleprompterDefaults {
    static let fontSize = "teleprompter.fontSize"
    static let wordsPerMinute = "teleprompter.wordsPerMinute"
    static let backdrop = "teleprompter.backdrop"
}

/// Backdrop presets: a fixed, tasteful set instead of a color picker. Each pairs
/// a translucent backdrop with matching text and control colors, so a light
/// video no longer swallows the strip.
struct TeleprompterBackdrop {
    let name: String
    let background: NSColor
    let editingBackground: NSColor
    let border: NSColor
    let text: NSColor
    let controls: NSColor

    static let all: [TeleprompterBackdrop] = [
        TeleprompterBackdrop(
            name: "Graphite",
            background: NSColor.black.withAlphaComponent(0.58),
            editingBackground: NSColor.black.withAlphaComponent(0.8),
            border: NSColor.white.withAlphaComponent(0.10),
            text: .white,
            controls: NSColor.white.withAlphaComponent(0.8)
        ),
        TeleprompterBackdrop(
            name: "Midnight",
            background: NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.32, alpha: 0.7),
            editingBackground: NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.32, alpha: 0.88),
            border: NSColor.white.withAlphaComponent(0.12),
            text: .white,
            controls: NSColor.white.withAlphaComponent(0.8)
        ),
        TeleprompterBackdrop(
            name: "Paper",
            background: NSColor(calibratedWhite: 0.97, alpha: 0.8),
            editingBackground: NSColor(calibratedWhite: 0.97, alpha: 0.94),
            border: NSColor.black.withAlphaComponent(0.14),
            text: NSColor(calibratedWhite: 0.06, alpha: 1),
            controls: NSColor.black.withAlphaComponent(0.62)
        )
    ]
}

enum TeleprompterLimits {
    static let minimumFontSize: CGFloat = 22
    static let maximumFontSize: CGFloat = 60
    /// ≈100 Chinese characters per minute: deliberate, but still speech.
    static let minimumWordsPerMinute: Double = 60
    /// Natural pace (≈220 characters per minute) sits at the slider's centre.
    static let centerWordsPerMinute: Double = 130
    /// ≈1,200 characters per minute: unambiguously faster than anyone reads.
    static let maximumWordsPerMinute: Double = 700

    /// Two linear segments hinged at the centre: the left half spans
    /// slow-to-natural, the right half natural-to-sprint, so the middle of the
    /// travel is always the calibrated speaking pace.
    static func speed(forSliderValue value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        if clamped <= 0.5 {
            return minimumWordsPerMinute
                + (centerWordsPerMinute - minimumWordsPerMinute) * clamped / 0.5
        }
        return centerWordsPerMinute
            + (maximumWordsPerMinute - centerWordsPerMinute) * (clamped - 0.5) / 0.5
    }

    static func sliderValue(forSpeed speed: Double) -> Double {
        let clamped = min(max(speed, minimumWordsPerMinute), maximumWordsPerMinute)
        if clamped <= centerWordsPerMinute {
            return (clamped - minimumWordsPerMinute)
                / (centerWordsPerMinute - minimumWordsPerMinute) * 0.5
        }
        return 0.5 + (clamped - centerWordsPerMinute)
            / (maximumWordsPerMinute - centerWordsPerMinute) * 0.5
    }
    /// Long lines make the eyes sweep sideways, which is obvious on camera, so
    /// the text column stays narrow no matter how wide the overlay is.
    static let maximumTextWidth: CGFloat = 620
}

/// Borderless overlay that can take keyboard focus for in-place script editing.
/// It is a separate window rather than a subview so it can carry
/// `sharingType = .none`: the script never appears in any screen capture.
private final class TeleprompterOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// First click goes to editing, and never drags the window: the overlay is glued
/// to the preview stage, it is not a window the user should move.
private final class TeleprompterContainerView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Clips the scrolling text and fades it out toward the top and bottom edges,
/// keeping the line being read in the bright middle band.
private final class FadingClipView: NSView {
    private let fadeMask = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        fadeMask.colors = [
            NSColor.clear.cgColor,
            NSColor.black.cgColor,
            NSColor.black.cgColor,
            NSColor.clear.cgColor
        ]
        fadeMask.locations = [0, 0.2, 0.8, 1]
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.mask = fadeMask
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        CATransaction.commit()
    }
}

/// The empty-script hint. It floats over the text view instead of living in
/// it, so it can never be clicked, edited or saved into the script — and it
/// lets every click fall through to the text underneath.
private final class PlaceholderLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class TeleprompterController: NSObject, NSTextViewDelegate, NSWindowDelegate {
    /// Fired on show/hide so the header toggle can mirror the real state even
    /// when the overlay is closed from its own ✕ button.
    var onVisibilityChanged: ((Bool) -> Void)?

    /// Only ever what the user wrote. Empty is a real state, not a cue to fill
    /// in instructions — those live in `placeholderLabel`.
    private(set) var script: String = ""
    var hasScript: Bool { !script.isEmpty }
    private(set) var isEditing = false

    private weak var hostWindow: NSWindow?
    private weak var stageView: NSView?
    private var overlayWindow: TeleprompterOverlayWindow?
    private var containerView: NSView?
    private var scrollView: NSScrollView?
    private var textView: NSTextView?
    private var playButton: NSButton?
    private var speedSlider: NSSlider?
    private var editHintLabel: NSTextField?
    private var placeholderLabel: NSTextField?
    private var clickRecognizer: NSClickGestureRecognizer?
    private var scrollTimer: Timer?
    private var scrollOffset: CGFloat = 0
    /// The clip-view position the timer last applied. When the actual position
    /// has moved away from this on its own, the user dragged the script — that
    /// is the only other writer — and the drag becomes the new baseline.
    private var lastAppliedScrollY: CGFloat = 0
    private var scrollStartedAt: TimeInterval?
    private var lastTickUptime: TimeInterval?
    private var wordCount = 1
    private var recordingLocked = false

    private var fontSize: CGFloat
    private var wordsPerMinute: Double
    private var backdropIndex: Int
    private let persistsScript: Bool
    /// Lets other recorders see the script, so OneAct's own demo videos can
    /// show the prompter. Off unless launched with --capturable-prompter.
    private let capturable: Bool
    private var swatchButtons: [NSButton] = []
    private var tintedControls: [NSView] = []

    private var currentBackdrop: TeleprompterBackdrop { TeleprompterBackdrop.all[backdropIndex] }
    var playControlEnabled: Bool { playButton?.isEnabled ?? true }

    /// Measured pace of the current layout, for the layout report: what the
    /// setting actually produces, rather than what it nominally means.
    func paceDiagnostics() -> (documentHeight: CGFloat, visibleHeight: CGFloat, units: Int, secondsToEnd: Double, charactersPerMinute: Double) {
        let documentHeight = textView?.frame.height ?? 0
        let visibleHeight = scrollView?.contentSize.height ?? 0
        let distance = max(0, documentHeight - visibleHeight)
        let pointsPerSecond = Self.pointsPerSecond(
            distance: distance,
            wordCount: wordCount,
            wordsPerMinute: wordsPerMinute
        )
        let seconds = pointsPerSecond > 0 ? Double(distance / pointsPerSecond) : 0
        let characters = Double(script.count)
        let charactersPerMinute = seconds > 0 ? characters / seconds * 60 : 0
        return (documentHeight, visibleHeight, wordCount, seconds, charactersPerMinute)
    }

    /// The overlay itself, for the layout report to render and inspect.
    var overlayWindowForDiagnostics: NSWindow? { overlayWindow }

    var isVisible: Bool { overlayWindow?.isVisible == true }
    var isScrolling: Bool { scrollTimer != nil }

    init(persistsScript: Bool = true, capturable: Bool = false) {
        self.persistsScript = persistsScript
        self.capturable = capturable
        let defaults = UserDefaults.standard
        let storedFontSize = CGFloat(defaults.double(forKey: TeleprompterDefaults.fontSize))
        let storedSpeed = defaults.double(forKey: TeleprompterDefaults.wordsPerMinute)
        fontSize = storedFontSize > 0 ? storedFontSize : 34
        wordsPerMinute = storedSpeed > 0 ? storedSpeed : 130
        let storedBackdrop = defaults.integer(forKey: TeleprompterDefaults.backdrop)
        backdropIndex = (0..<TeleprompterBackdrop.all.count).contains(storedBackdrop) ? storedBackdrop : 0
        super.init()
        if persistsScript {
            script = Self.loadScriptFromDisk() ?? ""
        }
    }

    /// Ties the overlay to the preview stage it should hug.
    func attach(stage: NSView, host: NSWindow) {
        stageView = stage
        hostWindow = host
        stage.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stageGeometryChanged),
            name: NSView.frameDidChangeNotification,
            object: stage
        )
    }

    // MARK: - Script persistence

    /// Saves even an empty script: clearing the prompter has to reach the disk,
    /// or the previous script comes back on the next launch.
    func setScript(_ newScript: String) {
        script = newScript
        if persistsScript { Self.saveScriptToDisk(newScript) }
        applyScript()
    }

    private static var scriptURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = base.appendingPathComponent("OneAct", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("script.txt")
        // 从改名前的 QuickCanvas 目录迁移已有脚本
        if !FileManager.default.fileExists(atPath: file.path) {
            let legacy = base.appendingPathComponent("QuickCanvas/script.txt")
            if FileManager.default.fileExists(atPath: legacy.path) {
                try? FileManager.default.copyItem(at: legacy, to: file)
            }
        }
        return file
    }

    private static func loadScriptFromDisk() -> String? {
        guard let url = scriptURL, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return text.isEmpty ? nil : text
    }

    private static func saveScriptToDisk(_ script: String) {
        guard let url = scriptURL else { return }
        try? script.write(to: url, atomically: true, encoding: .utf8)
    }

    private static let placeholderPrompt = "Click here to write or paste your script"
    private static let placeholderEditingPrompt = "Write or paste your script"
    private static let placeholderTip = "Blank lines become breathing room — one thought per block reads best on camera."

    // MARK: - Visibility

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let host = hostWindow else { return }
        let overlay = overlayWindow ?? makeOverlayWindow()
        overlayWindow = overlay
        applyScript()
        syncOverlayFrame()
        if overlay.parent == nil {
            host.addChildWindow(overlay, ordered: .above)
        }
        overlay.orderFront(nil)
        onVisibilityChanged?(true)
    }

    func hide() {
        commitEditing()
        stopScrolling()
        if let overlay = overlayWindow {
            overlay.parent?.removeChildWindow(overlay)
            overlay.orderOut(nil)
        }
        onVisibilityChanged?(false)
    }

    /// Recording locks the script: a stray click must not swap the text or steal
    /// keyboard focus while the presenter is speaking.
    func lockForRecording() {
        commitEditing()
        recordingLocked = true
        clickRecognizer?.isEnabled = false
    }

    func unlockAfterRecording() {
        recordingLocked = false
        clickRecognizer?.isEnabled = true
    }

    // MARK: - Overlay window

    private func makeOverlayWindow() -> TeleprompterOverlayWindow {
        let overlay = TeleprompterOverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        // The script is for the presenter only — invisible to our own recording
        // and to any other capture (meeting shares included). The capturable
        // exception exists only for filming OneAct itself.
        overlay.sharingType = capturable ? .readOnly : .none
        overlay.delegate = self
        overlay.contentView = makeContentView()
        return overlay
    }

    @objc private func stageGeometryChanged() {
        syncOverlayFrame()
    }

    /// The overlay hugs the top band of the preview stage, so the script reads
    /// as part of the preview. Child-window mechanics keep it glued when the
    /// main window moves; this handles resizes.
    private func syncOverlayFrame() {
        guard let stage = stageView, let host = hostWindow, let overlay = overlayWindow else { return }
        let inset: CGFloat = 14
        let stageOnScreen = host.convertToScreen(stage.convert(stage.bounds, to: nil))
        let height = min(max(stageOnScreen.height * 0.42, 120), 240)
        overlay.setFrame(
            NSRect(
                x: stageOnScreen.minX + inset,
                y: stageOnScreen.maxY - inset - height,
                width: stageOnScreen.width - inset * 2,
                height: height
            ),
            display: true
        )
    }

    private func makeContentView() -> NSView {
        let container = TeleprompterContainerView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.cornerCurve = .continuous
        container.layer?.borderWidth = 1
        container.toolTip = "Click the text to edit the script"
        containerView = container

        let clip = FadingClipView(frame: .zero)
        clip.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(clip)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewFrameChanged),
            name: NSView.frameDidChangeNotification,
            object: scrollView
        )
        clip.addSubview(scrollView)
        self.scrollView = scrollView

        let textView = NSTextView()
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.alignment = .center
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        self.textView = textView

        // Added after the scroll view so it draws on top of the empty text.
        let placeholder = PlaceholderLabel(wrappingLabelWithString: "")
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isSelectable = false
        placeholder.alignment = .center
        clip.addSubview(placeholder)
        placeholderLabel = placeholder

        let controlBar = makeControlBar()
        controlBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controlBar)

        NSLayoutConstraint.activate([
            clip.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            clip.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            clip.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            clip.bottomAnchor.constraint(equalTo: controlBar.topAnchor, constant: -2),

            scrollView.topAnchor.constraint(equalTo: clip.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            scrollView.centerXAnchor.constraint(equalTo: clip.centerXAnchor),
            scrollView.widthAnchor.constraint(
                lessThanOrEqualToConstant: TeleprompterLimits.maximumTextWidth
            ),
            scrollView.leadingAnchor.constraint(greaterThanOrEqualTo: clip.leadingAnchor),
            scrollView.trailingAnchor.constraint(lessThanOrEqualTo: clip.trailingAnchor),

            placeholder.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: clip.centerYAnchor),
            placeholder.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -24),

            controlBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            controlBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            controlBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            controlBar.heightAnchor.constraint(equalToConstant: 20)
        ])
        let preferredWidth = scrollView.widthAnchor.constraint(equalTo: clip.widthAnchor)
        preferredWidth.priority = .defaultLow
        preferredWidth.isActive = true

        // Editing starts with a click on the text itself — the recognizer sits on
        // the clip view so the control-bar buttons stay ordinary buttons.
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(overlayClicked))
        clip.addGestureRecognizer(recognizer)
        clickRecognizer = recognizer
        applyBackdrop()
        return container
    }

    private func makeControlBar() -> NSView {
        let play = iconButton("play.fill", tooltip: "Start or pause scrolling", action: #selector(togglePlay))
        playButton = play

        // Tortoise-to-hare slider: speed reads as a feel, not as a number the
        // presenter has to interpret.
        let slider = NSSlider(
            value: TeleprompterLimits.sliderValue(forSpeed: wordsPerMinute),
            minValue: 0,
            maxValue: 1,
            target: self,
            action: #selector(speedSliderChanged)
        )
        slider.controlSize = .small
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 96).isActive = true
        speedSlider = slider
        updateSpeedTooltip()

        let hint = NSTextField(labelWithString: "Esc or click outside saves")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = NSColor.white.withAlphaComponent(0.55)
        hint.isHidden = true
        editHintLabel = hint

        swatchButtons = TeleprompterBackdrop.all.enumerated().map { index, preset in
            makeSwatchButton(index: index, preset: preset)
        }
        let smallerText = iconButton(
            "textformat.size.smaller",
            tooltip: "Smaller text",
            action: #selector(decreaseFont),
            width: 15
        )
        let largerText = iconButton(
            "textformat.size.larger",
            tooltip: "Bigger text",
            action: #selector(increaseFont),
            width: 15
        )
        let stack = NSStackView(views: [
            play,
            iconButton("arrow.up.to.line", tooltip: "Back to the top", action: #selector(scrollToTop)),
            speedIcon("tortoise.fill", tooltip: "Slower"),
            slider,
            speedIcon("hare.fill", tooltip: "Faster"),
            smallerText,
            largerText
        ] + swatchButtons + [hint])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        // The two text-size icons are one control in spirit — no gap between them.
        stack.setCustomSpacing(0, after: smallerText)
        return stack
    }

    private func speedIcon(_ symbol: String, tooltip: String) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        view.toolTip = tooltip
        tintedControls.append(view)
        return view
    }

    private func iconButton(
        _ symbol: String,
        tooltip: String,
        action: Selector,
        width: CGFloat = 22
    ) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        tintedControls.append(button)
        return button
    }

    private func makeSwatchButton(index: Int, preset: TeleprompterBackdrop) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(backdropSelected(_:)))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.tag = index
        button.toolTip = "\(preset.name) backdrop"
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.borderWidth = 1
        // Opaque version of the backdrop, so the swatch reads no matter what
        // video happens to be behind the strip.
        button.layer?.backgroundColor = preset.background.withAlphaComponent(1).cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 12).isActive = true
        button.heightAnchor.constraint(equalToConstant: 12).isActive = true
        return button
    }

    @objc private func backdropSelected(_ sender: NSButton) {
        backdropIndex = sender.tag
        UserDefaults.standard.set(backdropIndex, forKey: TeleprompterDefaults.backdrop)
        applyBackdrop()
        restyleScript()
    }

    /// Everything whose color depends on the backdrop, in one place.
    private func applyBackdrop() {
        let preset = currentBackdrop
        containerView?.layer?.backgroundColor =
            (isEditing ? preset.editingBackground : preset.background).cgColor
        containerView?.layer?.borderColor = isEditing
            ? NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            : preset.border.cgColor
        textView?.insertionPointColor = preset.text
        editHintLabel?.textColor = preset.text.withAlphaComponent(0.55)
        updatePlaceholder()
        for control in tintedControls {
            if let button = control as? NSButton {
                button.contentTintColor = preset.controls
            } else if let image = control as? NSImageView {
                image.contentTintColor = preset.controls.withAlphaComponent(0.75)
            }
        }
        for (index, swatch) in swatchButtons.enumerated() {
            let selected = index == backdropIndex
            swatch.layer?.borderWidth = selected ? 2 : 1
            swatch.layer?.borderColor = selected
                ? NSColor.controlAccentColor.cgColor
                : preset.controls.withAlphaComponent(0.35).cgColor
        }
    }

    // MARK: - In-place editing

    @objc private func overlayClicked() {
        beginEditing()
    }

    func beginEditing() {
        guard !recordingLocked, !isEditing, let overlay = overlayWindow, let textView else { return }
        stopScrolling()
        isEditing = true
        clickRecognizer?.isEnabled = false
        textView.isEditable = true
        textView.isSelectable = true
        updatePlayAvailability()
        applyBackdrop()
        editHintLabel?.isHidden = false
        overlay.makeKey()
        overlay.makeFirstResponder(textView)
    }

    /// Commits whatever is in the text view. There is no cancel path — the
    /// overlay is the document, saving is the only outcome.
    func commitEditing() {
        guard isEditing, let textView else { return }
        isEditing = false
        clickRecognizer?.isEnabled = !recordingLocked
        textView.isEditable = false
        textView.isSelectable = false
        applyBackdrop()
        editHintLabel?.isHidden = true

        // Whitespace alone is not a script: store it as empty so the
        // placeholder comes back instead of a blank, playable strip.
        let text = textView.string
        let written = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
        if written != script {
            setScript(written)
        } else {
            applyScript()
        }
        if overlayWindow?.isKeyWindow == true {
            hostWindow?.makeKey()
        }
    }

    func textDidChange(_ notification: Notification) {
        updatePlaceholder()
    }

    func textDidEndEditing(_ notification: Notification) {
        commitEditing()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            commitEditing()
            return true
        }
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === overlayWindow else { return }
        commitEditing()
    }

    // MARK: - Rendering

    private var scriptAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineHeightMultiple = 1.25
        paragraph.paragraphSpacing = fontSize * 0.6
        return [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: currentBackdrop.text,
            .paragraphStyle: paragraph
        ]
    }

    /// For a font or backdrop change. While editing, the text view holds typing
    /// that is not saved yet, so it is restyled where it stands — replacing it
    /// with `script` threw that typing away.
    private func restyleScript() {
        guard isEditing, let textView, let storage = textView.textStorage else {
            applyScript()
            return
        }
        let attributes = scriptAttributes
        let selection = textView.selectedRanges
        storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        textView.typingAttributes = attributes
        textView.selectedRanges = selection
        updateReadingInset()
        updatePlaceholder()
    }

    private func applyScript() {
        guard let textView else { return }
        let attributes = scriptAttributes
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: script, attributes: attributes)
        )
        textView.typingAttributes = attributes
        wordCount = Self.estimatedWordCount(of: script)
        updateReadingInset()
        scrollToTop()
        updatePlaceholder()
        updatePlayAvailability()
    }

    /// The instructions show only while there is no text at all, muted so they
    /// read as a hint rather than as the script.
    private func updatePlaceholder() {
        guard let placeholderLabel, let textView else { return }
        let isEmpty = textView.string.isEmpty
        placeholderLabel.isHidden = !isEmpty
        guard isEmpty else { return }

        let color = currentBackdrop.text
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let hint = NSMutableAttributedString(
            string: (isEditing ? Self.placeholderEditingPrompt : Self.placeholderPrompt) + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 17, weight: .medium),
                .foregroundColor: color.withAlphaComponent(0.5),
                .paragraphStyle: paragraph
            ]
        )
        hint.append(NSAttributedString(
            string: Self.placeholderTip,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: color.withAlphaComponent(0.38),
                .paragraphStyle: paragraph
            ]
        ))
        placeholderLabel.attributedStringValue = hint
    }

    /// Play needs something to scroll and cannot run while the text is being
    /// rewritten, so it greys out instead of silently ignoring the click.
    private func updatePlayAvailability() {
        let available = hasScript && !isEditing
        playButton?.isEnabled = available
        playButton?.alphaValue = available ? 1 : 0.35
        playButton?.toolTip = hasScript ? "Start or pause scrolling" : "Write a script to start scrolling"
    }

    /// Chinese is spoken at roughly 220 characters per minute where English runs
    /// about 130 words per minute, so a character is about 1/1.7 of a word in
    /// speaking time. Counting characters one-for-one made the same slider
    /// position mean two very different paces; this converts CJK characters into
    /// word-equivalents so one speed setting fits both scripts.
    static let charactersPerSpokenWord = 1.7

    static func estimatedWordCount(of text: String) -> Int {
        var cjkCount = 0
        var wordCount = 0
        var insideWord = false
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isCJK = (0x4E00...0x9FFF).contains(value)
                || (0x3400...0x4DBF).contains(value)
                || (0xF900...0xFAFF).contains(value)
                || (0x3040...0x30FF).contains(value)
                || (0xAC00...0xD7AF).contains(value)
            if isCJK {
                cjkCount += 1
                insideWord = false
            } else if scalar.properties.isAlphabetic || (0x30...0x39).contains(value) {
                if !insideWord {
                    wordCount += 1
                    insideWord = true
                }
            } else {
                insideWord = false
            }
        }
        let cjkWordEquivalents = Int((Double(cjkCount) / charactersPerSpokenWord).rounded(.up))
        return max(1, cjkWordEquivalents + wordCount)
    }

    @objc private func scrollViewFrameChanged() {
        updateReadingInset()
    }

    /// Padding above and below the text, so the first and last lines can still
    /// reach the bright middle band of the fade.
    private func updateReadingInset() {
        guard let scrollView, let textView else { return }
        let inset = max(20, scrollView.contentSize.height / 2 - fontSize)
        guard abs(textView.textContainerInset.height - inset) > 0.5 else { return }
        textView.textContainerInset = NSSize(width: 0, height: inset)
    }

    // MARK: - Scrolling

    func startScrolling() {
        guard isVisible, !isEditing, hasScript, scrollTimer == nil else { return }
        // Wherever the script sits right now is where scrolling continues
        // from. Only the timer writes `scrollOffset`, so a script dragged to a
        // new spot — typically while paused mid-take — otherwise snapped back
        // to the pre-pause position on the first tick.
        if let scrollView {
            scrollOffset = max(0, scrollView.contentView.bounds.origin.y)
            lastAppliedScrollY = scrollOffset
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceScroll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollTimer = timer
        scrollStartedAt = ProcessInfo.processInfo.systemUptime
        lastTickUptime = nil
        playButton?.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")
    }

    func stopScrolling() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        scrollStartedAt = nil
        playButton?.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
    }

    private func advanceScroll() {
        guard let scrollView, let textView else { return }
        let distance = textView.frame.height - scrollView.contentSize.height
        guard distance > 0 else { return }

        // A drag during playback moves the clip view without touching
        // `scrollOffset`; integrating from the stale value would snap the
        // script back on this very tick. The threshold stays above any
        // rounding the view applies, so programmatic scrolls never trip it.
        let actualY = scrollView.contentView.bounds.origin.y
        if abs(actualY - lastAppliedScrollY) > 1 {
            scrollOffset = max(0, actualY)
        }

        let now = ProcessInfo.processInfo.systemUptime
        // Integrate over real elapsed time. The timer coalesces whenever the main
        // thread is busy compositing preview frames, so assuming a fixed 1/60
        // tick made the script crawl exactly when the app was working hardest.
        let delta = min(now - (lastTickUptime ?? now), 0.25)
        lastTickUptime = now

        // Ease into the scroll — full speed from a standing start reads as the
        // text running away.
        let ramp = min(1, (now - (scrollStartedAt ?? now)) / 1.2)
        scrollOffset = min(
            scrollOffset + Self.pointsPerSecond(
                distance: distance,
                wordCount: wordCount,
                wordsPerMinute: wordsPerMinute
            ) * CGFloat(delta * ramp),
            distance
        )
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollOffset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        // Read back rather than assume: the view may quantize the position to
        // the pixel grid, and the drag detector compares against what actually
        // landed, not what was asked for.
        lastAppliedScrollY = scrollView.contentView.bounds.origin.y
        if scrollOffset >= distance { stopScrolling() }
    }

    /// Traverses the whole script in `wordCount / wordsPerMinute` minutes, so the
    /// setting means what it says regardless of layout.
    static func pointsPerSecond(
        distance: CGFloat,
        wordCount: Int,
        wordsPerMinute: Double
    ) -> CGFloat {
        distance * CGFloat(wordsPerMinute) / (60 * CGFloat(max(1, wordCount)))
    }

    // MARK: - Control actions

    @objc private func togglePlay() {
        isScrolling ? stopScrolling() : startScrolling()
    }

    @objc func scrollToTop() {
        scrollOffset = 0
        lastAppliedScrollY = 0
        scrollView?.contentView.scroll(to: .zero)
        scrollView.map { $0.reflectScrolledClipView($0.contentView) }
    }

    func setSpeedForDiagnostics(_ value: Double) {
        wordsPerMinute = value
    }

    /// Swaps the on-screen text for measurements WITHOUT persisting: the layout
    /// report must never overwrite the user's saved script (it did, once).
    func setScriptForDiagnostics(_ text: String) {
        script = text
        applyScript()
    }

    private func updateSpeedTooltip() {
        speedSlider?.toolTip = String(
            format: "Scrolling speed · ≈%.0f Chinese characters or %.0f English words per minute",
            wordsPerMinute * Self.charactersPerSpokenWord,
            wordsPerMinute
        )
    }

    @objc private func speedSliderChanged() {
        guard let speedSlider else { return }
        wordsPerMinute = TeleprompterLimits.speed(forSliderValue: speedSlider.doubleValue)
        UserDefaults.standard.set(wordsPerMinute, forKey: TeleprompterDefaults.wordsPerMinute)
        updateSpeedTooltip()
    }

    @objc private func decreaseFont() { adjustFont(by: -4) }
    @objc private func increaseFont() { adjustFont(by: 4) }

    private func adjustFont(by delta: CGFloat) {
        fontSize = min(
            max(fontSize + delta, TeleprompterLimits.minimumFontSize),
            TeleprompterLimits.maximumFontSize
        )
        UserDefaults.standard.set(Double(fontSize), forKey: TeleprompterDefaults.fontSize)
        restyleScript()
    }
}
