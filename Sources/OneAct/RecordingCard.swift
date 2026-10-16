import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// What a finished take offers before the next one: watch it, name it, find
/// it, hand it to another app, or throw it away and go again. One take is the
/// whole product — a flub means a retake — so "Discard & Retake" sits next to
/// the file rather than behind a trip to Finder and the Trash.
///
/// The card is non-modal and sits over the bottom of the preview stage: the
/// recorder stays fully usable behind it, and starting the next take simply
/// closes it. Closing it never touches the file.
@MainActor
final class RecordingCardView: NSView, NSTextFieldDelegate {
    var onPlay: (() -> Void)?
    /// Proposes a new base name; the owner renames the file and returns where
    /// it went, or the reason it could not.
    var onRename: ((String) -> Result<URL, Error>)?
    var onShowInFinder: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let thumbnail = RecordingDragHandle()
    private let nameField = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private(set) lazy var playButton = cardButton("Play", symbol: "play.fill", action: #selector(play))
    private(set) lazy var renameButton = cardButton("Rename", symbol: "pencil", action: #selector(rename))
    private(set) lazy var finderButton = cardButton("Show in Finder", symbol: "folder", action: #selector(showInFinder))
    private(set) lazy var discardButton = cardButton(
        "Discard & Retake", symbol: "arrow.counterclockwise", action: #selector(discard)
    )
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private(set) var url: URL?
    private(set) var isRenaming = false
    /// Bumped per take so a slow poster frame cannot land on the next take's card.
    private var generation = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The stage is dark in three of its four backdrops; a dark card reads
        // on all of them and keeps the controls in their dark variants.
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 0.94).cgColor
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 14
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            return shadow
        }()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Recording saved")
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var buttonTitles: [String] {
        [playButton, renameButton, finderButton, discardButton].map(\.title) + ["×"]
    }

    func show(url: URL, detail: String) {
        finishRenaming(commit: false)
        generation += 1
        self.url = url
        thumbnail.fileURL = url
        thumbnail.image = NSWorkspace.shared.icon(for: .quickTimeMovie)
        nameField.stringValue = url.lastPathComponent
        nameField.toolTip = url.path
        detailLabel.stringValue = detail
        isHidden = false
        updateCloseShortcut()
        loadPosterFrame(for: url, generation: generation)
    }

    /// A name still being typed when the card goes — the next take started
    /// from the hotkey, say — is kept, as clicking away from it would.
    func hide() {
        finishRenaming(commit: true)
        generation += 1
        url = nil
        thumbnail.fileURL = nil
        isHidden = true
        updateCloseShortcut()
    }

    func beginRenaming() {
        guard let url, !isRenaming else { return }
        isRenaming = true
        updateCloseShortcut()
        renameButton.title = "Done"
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.isBezeled = true
        nameField.bezelStyle = .roundedBezel
        nameField.drawsBackground = true
        nameField.lineBreakMode = .byClipping
        nameField.stringValue = url.deletingPathExtension().lastPathComponent
        window?.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    func finishRenaming(commit: Bool) {
        guard isRenaming else { return }
        // Cleared first: giving up first responder below re-enters through
        // controlTextDidEndEditing.
        isRenaming = false
        let proposed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editor = nameField.currentEditor(), window?.firstResponder === editor {
            window?.makeFirstResponder(nil)
        }
        updateCloseShortcut()
        renameButton.title = "Rename"
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.lineBreakMode = .byTruncatingMiddle
        guard let url else { return }
        if commit, !proposed.isEmpty, proposed != url.deletingPathExtension().lastPathComponent,
           case .success(let renamed)? = onRename?(proposed) {
            self.url = renamed
            thumbnail.fileURL = renamed
            nameField.toolTip = renamed.path
        }
        nameField.stringValue = (self.url ?? url).lastPathComponent
    }

    // MARK: Actions

    @objc private func play() {
        finishRenaming(commit: true)
        onPlay?()
    }

    @objc private func rename() {
        if isRenaming { finishRenaming(commit: true) } else { beginRenaming() }
    }

    @objc private func showInFinder() {
        finishRenaming(commit: true)
        onShowInFinder?()
    }

    @objc private func discard() {
        finishRenaming(commit: false)
        onDiscard?()
    }

    @objc private func dismiss() {
        finishRenaming(commit: true)
        onDismiss?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard isRenaming else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            finishRenaming(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finishRenaming(commit: false)
            return true
        default:
            return false
        }
    }

    /// Clicking elsewhere keeps what was typed, as Finder does.
    func controlTextDidEndEditing(_ obj: Notification) {
        finishRenaming(commit: true)
    }

    // MARK: Layout

    private func buildLayout() {
        thumbnail.onOpen = { [weak self] in self?.play() }
        thumbnail.translatesAutoresizingMaskIntoConstraints = false

        nameField.font = .systemFont(ofSize: 13, weight: .semibold)
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.maximumNumberOfLines = 1
        nameField.cell?.usesSingleLineMode = true
        nameField.delegate = self
        nameField.focusRingType = .none
        // Each line keeps its natural width — above the stack's wish to make
        // them match — and gives way only when the stage itself is too
        // narrow, which is what the middle truncation is for.
        nameField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.dragThatCannotResizeWindow, for: .horizontal)
        nameField.setAccessibilityLabel("File name")

        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.dragThatCannotResizeWindow, for: .horizontal)

        let text = NSStackView(views: [nameField, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setHuggingPriority(.defaultLow, for: .horizontal)

        playButton.toolTip = "Watch the take in Quick Look"
        renameButton.toolTip = "Rename the file"
        finderButton.toolTip = "Reveal the file in Finder"
        discardButton.toolTip = "Move this take to the Trash and get ready to record it again"
        // Red like Record: this is the button that leads straight back to it.
        discardButton.contentTintColor = .systemRed
        discardButton.attributedTitle = NSAttributedString(
            string: discardButton.title,
            attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: discardButton.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            ]
        )

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(dismiss)
        closeButton.toolTip = "Keep the take and close this card (Esc)"

        let row = NSStackView(views: [
            thumbnail, text, playButton, renameButton, finderButton, discardButton, closeButton
        ])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.setCustomSpacing(12, after: thumbnail)
        row.setCustomSpacing(14, after: text)
        row.setCustomSpacing(10, after: discardButton)
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            thumbnail.widthAnchor.constraint(equalToConstant: 76),
            thumbnail.heightAnchor.constraint(equalToConstant: 44),
            text.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            nameField.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    /// Esc closes the card only while it is on screen, and never while
    /// renaming: there it belongs to the field editor, to cancel the new name.
    private func updateCloseShortcut() {
        closeButton.keyEquivalent = !isHidden && !isRenaming ? "\u{1b}" : ""
    }

    private func cardButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(
            title: title,
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(),
            target: self,
            action: action
        )
        button.bezelStyle = .rounded
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    private func loadPosterFrame(for url: URL, generation: Int) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        Task { [weak self] in
            guard let frame = try? await generator.image(at: .zero).image else { return }
            guard let self, self.generation == generation else { return }
            self.thumbnail.image = NSImage(cgImage: frame, size: .zero)
        }
    }
}

/// The take's poster frame doubles as the file itself: drag it into Finder,
/// Mail, or a browser upload, and the recording goes with it.
@MainActor
final class RecordingDragHandle: NSImageView, NSDraggingSource {
    var fileURL: URL?
    var onOpen: (() -> Void)?
    private var mouseDownEvent: NSEvent?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        toolTip = "Drag the recording into another app or a Finder folder · double-click to play"
        setAccessibilityLabel("Recording file")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The window moves by its background; without this a drag from the
    // thumbnail would move the window instead of the file.
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        super.resetCursorRects()
        if fileURL != nil { addCursorRect(bounds, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            mouseDownEvent = nil
            onOpen?()
            return
        }
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let url = fileURL, let down = mouseDownEvent else { return }
        let start = down.locationInWindow
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }
        mouseDownEvent = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image ?? NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [item], event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    /// Copy, never move: the take stays where OneAct put it, so the card's
    /// other actions still point at a file that exists.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}
