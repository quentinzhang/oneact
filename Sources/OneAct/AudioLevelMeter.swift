import AppKit
import QuartzCore

/// Live microphone meter sitting next to the Record button.
///
/// It exists to answer one question *before* a take starts rather than after:
/// is the microphone actually hearing anything. A muted hardware switch, a
/// lavalier that never powered on, or a device that quietly fell back to the
/// wrong input all look identical until something moves here — and this app
/// already shipped a bug where a silent file passed for a good recording.
///
/// The display decays on its own rather than holding the last value it was
/// given, so an input that stalls falls to silence instead of freezing
/// mid-scale and reading as healthy.
final class AudioLevelMeter: NSView {
    /// Everything quieter than this reads as silence. Speech averages around
    /// -30 dBFS and peaks near -10, so this floor puts a normal voice in the
    /// middle of the bar with headroom left to see clipping coming.
    private static let floorDB: Float = -56
    private static let segmentCount = 13
    /// Segments from here up are drawn hot — a voice riding in this zone is
    /// close enough to 0 dBFS to clip on a loud word.
    private static let hotSegmentIndex = 10
    private static let peakHoldDuration: CFTimeInterval = 1.1
    private static let frameInterval: TimeInterval = 1.0 / 30.0

    /// Whether an input exists at all. False dims the meter and shows a
    /// struck-through mic, which reads differently from a live-but-silent
    /// input — the two failures need different fixes.
    var inputAvailable = false {
        didSet {
            guard inputAvailable != oldValue else { return }
            if !inputAvailable {
                displayedLevel = 0
                targetLevel = 0
                peakLevel = 0
            }
            updateIcon()
            needsDisplay = true
        }
    }

    private let iconView = NSImageView()
    private var targetLevel: CGFloat = 0
    private var displayedLevel: CGFloat = 0
    private var peakLevel: CGFloat = 0
    private var peakSetAt: CFTimeInterval = 0
    private var decayTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    deinit {
        decayTimer?.invalidate()
    }

    private func setUp() {
        translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .tertiaryLabelColor
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 13),
            iconView.heightAnchor.constraint(equalToConstant: 13),
            widthAnchor.constraint(equalToConstant: 104),
            heightAnchor.constraint(equalToConstant: 14)
        ])
        updateIcon()
        toolTip = "Microphone input level"
    }

    private var barRect: NSRect {
        NSRect(x: 21, y: bounds.midY - 4, width: bounds.width - 21, height: 8)
    }

    private func updateIcon() {
        let name = inputAvailable ? "mic.fill" : "mic.slash.fill"
        iconView.image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: inputAvailable ? "Microphone level" : "No microphone"
        )
        iconView.contentTintColor = inputAvailable ? .secondaryLabelColor : .tertiaryLabelColor
    }

    /// Feed one reading, in dBFS, straight from the capture connection.
    func report(decibels: Float) {
        guard inputAvailable else { return }
        let clamped = max(Self.floorDB, min(0, decibels))
        targetLevel = CGFloat((clamped - Self.floorDB) / -Self.floorDB)
        startDecayTimerIfNeeded()
    }

    private func startDecayTimerIfNeeded() {
        guard decayTimer == nil else { return }
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        // The control panel and preview are live during a take; the default
        // run-loop mode would drop the meter the moment a menu opens.
        RunLoop.main.add(timer, forMode: .common)
        decayTimer = timer
    }

    private func step() {
        // Rise fast enough to catch a syllable, fall slowly enough to read.
        let smoothing: CGFloat = targetLevel > displayedLevel ? 0.55 : 0.16
        displayedLevel += (targetLevel - displayedLevel) * smoothing
        // Each reading only holds for one frame: an input that stops delivering
        // buffers must sink to silence rather than sit at its last value.
        targetLevel *= 0.82

        let now = CACurrentMediaTime()
        if displayedLevel >= peakLevel {
            peakLevel = displayedLevel
            peakSetAt = now
        } else if now - peakSetAt > Self.peakHoldDuration {
            peakLevel = max(displayedLevel, peakLevel - 0.03)
        }

        if displayedLevel < 0.002 && peakLevel < 0.002 {
            displayedLevel = 0
            targetLevel = 0
            peakLevel = 0
            decayTimer?.invalidate()
            decayTimer = nil
        }
        needsDisplay = true
    }

    private func color(forSegment index: Int) -> NSColor {
        if index >= Self.segmentCount - 1 { return .systemRed }
        if index >= Self.hotSegmentIndex { return .systemYellow }
        return .systemGreen
    }

    override func draw(_ dirtyRect: NSRect) {
        let bar = barRect
        let gap: CGFloat = 2
        let segmentWidth = (bar.width - gap * CGFloat(Self.segmentCount - 1)) / CGFloat(Self.segmentCount)
        guard segmentWidth > 0 else { return }

        let litCount = Int((displayedLevel * CGFloat(Self.segmentCount)).rounded(.up))
        let peakIndex = peakLevel > 0
            ? min(Self.segmentCount - 1, Int((peakLevel * CGFloat(Self.segmentCount)).rounded(.up)) - 1)
            : -1

        for index in 0..<Self.segmentCount {
            let rect = NSRect(
                x: bar.minX + (segmentWidth + gap) * CGFloat(index),
                y: bar.minY,
                width: segmentWidth,
                height: bar.height
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.2, yRadius: 1.2)
            if index < litCount {
                color(forSegment: index).setFill()
            } else if index == peakIndex {
                // The peak tick is the only thing that survives a pause between
                // words, which is what makes a quiet-but-working mic legible.
                color(forSegment: index).withAlphaComponent(0.55).setFill()
            } else {
                NSColor.tertiaryLabelColor.withAlphaComponent(inputAvailable ? 0.28 : 0.14).setFill()
            }
            path.fill()
        }
    }
}
