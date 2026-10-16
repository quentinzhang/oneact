import AppKit
import Carbon.HIToolbox

/// Space pauses and resumes a take while OneAct is in front.
///
/// Recording to camera, the presenter is looking at OneAct anyway, and Space
/// is the biggest key on the keyboard and the one everyone knows from video
/// players. It is not a global shortcut: while another app is being
/// demonstrated, Space belongs to that app, and ⌥⌘P is the shortcut that
/// works everywhere.
///
/// The app's key monitor sees Space before the window does, so a control
/// that happens to have keyboard focus — the record button above all, which
/// would stop the take — is never "pressed" by it. Space only ever pauses or
/// resumes; it never starts or stops a take.
enum SpacePause {
    enum Decision: String {
        /// Not ours: the key goes on to whatever would have received it.
        case pass
        case toggle
        /// Held down: auto-repeat must neither flicker the take nor reach a
        /// focused button.
        case swallow
    }

    static func decide(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isRepeat: Bool,
        takeRunning: Bool,
        inOneActWindow: Bool,
        typing: Bool
    ) -> Decision {
        guard keyCode == UInt16(kVK_Space), takeRunning, inOneActWindow, !typing else { return .pass }
        let held = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard held.isEmpty else { return .pass }
        return isRepeat ? .swallow : .toggle
    }
}

/// Over the preview while a take is paused. Words spoken now are not being
/// recorded, and a small pause icon is easy to miss when the presenter is
/// looking at the lens. Part of the window only, never of the recording.
final class PausedBadge: NSView {
    private let title = NSTextField(labelWithString: "Paused")
    private let detail = NSTextField(labelWithString: "Not recording · Space or ⌥⌘P to resume")

    /// ⌥⌘P is named only while it is actually registered.
    var globalShortcutAvailable = true {
        didSet {
            detail.stringValue = globalShortcutAvailable
                ? "Not recording · Space or ⌥⌘P to resume"
                : "Not recording · Space to resume"
            setAccessibilityLabel(globalShortcutAvailable
                ? "Recording paused. Press Space or Option-Command-P to resume."
                : "Recording paused. Press Space to resume.")
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Recording paused. Press Space or Option-Command-P to resume.")

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "pause.circle.fill",
            accessibilityDescription: nil
        ) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 30, weight: .semibold)
        icon.contentTintColor = .white
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        title.textColor = .white
        detail.font = .systemFont(ofSize: 13, weight: .medium)
        detail.textColor = NSColor.white.withAlphaComponent(0.78)

        let words = NSStackView(views: [title, detail])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        let row = NSStackView(views: [icon, words])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The badge sits over the preview but must not take its clicks or drags.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var reportText: String { "\(title.stringValue) | \(detail.stringValue)" }
}
