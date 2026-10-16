import AppKit

/// The Touch-up button in the CAMERA row and the small popover it opens: an
/// on/off switch, Light, Warmth and Smooth, and Reset. Owns its own controls
/// and persistence, so the main window only places the button and listens.
@MainActor
final class TouchUpControl: NSObject, NSPopoverDelegate {
    let button = NSButton(title: "Touch-up", target: nil, action: nil)
    /// Fires on every change, from the switch, a slider or Reset.
    var onChange: ((TouchUpSettings) -> Void)?
    private(set) var settings: TouchUpSettings

    private let persists: Bool
    private let panel: TouchUpPanelController
    private var popover: NSPopover?

    /// Composition locks follow the rest of the deck: free when idle or
    /// paused, fixed while a segment is being written.
    var isEditable = true {
        didSet {
            button.isEnabled = isEditable
            panel.isEditable = isEditable
            if !isEditable { popover?.performClose(nil) }
        }
    }

    /// False when the kernels could not compile on this Mac. The popover
    /// says so instead of offering sliders that would do nothing.
    var isAvailable = true {
        didSet { panel.isAvailable = isAvailable; updateButton() }
    }

    init(settings: TouchUpSettings, persists: Bool) {
        self.settings = settings
        self.persists = persists
        panel = TouchUpPanelController(settings: settings)
        super.init()
        panel.onChange = { [weak self] settings in self?.apply(settings) }
        button.target = self
        button.action = #selector(togglePopover)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11)
        button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Touch-up")
        button.imagePosition = .imageLeading
        updateButton()
    }

    /// One line for the status bar.
    var statusText: String {
        guard isAvailable else { return "Touch-up is unavailable on this Mac" }
        guard settings.enabled else { return "Touch-up off · the camera as it comes in" }
        guard settings.isActive else { return "Touch-up on · every slider at zero, nothing applied" }
        return "Touch-up on · " + TouchUpPanelController.summary(of: settings)
            + " · camera only, preview and recording both"
    }

    @objc private func togglePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = panel
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated { popover = nil }
    }

    /// Sets the controls as well as the look, for callers other than the
    /// popover itself (the layout report).
    func set(_ newSettings: TouchUpSettings) {
        panel.show(newSettings)
        apply(newSettings)
    }

    private func apply(_ newSettings: TouchUpSettings) {
        settings = newSettings
        if persists { newSettings.store() }
        updateButton()
        onChange?(newSettings)
    }

    private func updateButton() {
        let active = isAvailable && settings.isActive
        // The sparkles turn the accent colour while it is changing the
        // picture, so a recording never carries a look the user forgot was
        // switched on. A coloured symbol, not a tinted bezel: it has to read
        // while another app is in front, which is most of a screen recording.
        let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Touch-up")
        button.image = active
            ? symbol?.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor]))
            : symbol
        button.toolTip = active
            ? "Touch-up on · \(TouchUpPanelController.summary(of: settings)) · camera only"
            : "Touch-up · gentle light, warmth and skin smoothing for the camera, applied live to preview and recording"
    }

    /// The popover's content on an opaque card, for `--layout-report`.
    func reportSnapshot() -> NSBitmapImageRep? {
        panel.loadViewIfNeeded()
        let content = panel.view
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let card = NSView(frame: NSRect(origin: .zero, size: size))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        content.frame = card.bounds
        card.addSubview(content)
        card.layoutSubtreeIfNeeded()
        defer {
            content.removeFromSuperview()
        }
        guard let bitmap = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { return nil }
        card.cacheDisplay(in: card.bounds, to: bitmap)
        return bitmap
    }

    var reportDescription: String {
        panel.loadViewIfNeeded()
        return panel.reportDescription
    }
}

@MainActor
private final class TouchUpPanelController: NSViewController {
    var onChange: ((TouchUpSettings) -> Void)?
    var isEditable = true { didSet { updateEnabled() } }
    var isAvailable = true { didSet { updateEnabled() } }

    private var settings: TouchUpSettings
    private let enabledSwitch = NSSwitch()
    private let lightSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let warmthSlider = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let smoothSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let lightValue = TouchUpPanelController.valueLabel()
    private let warmthValue = TouchUpPanelController.valueLabel()
    private let smoothValue = TouchUpPanelController.valueLabel()
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private let footnote = NSTextField(wrappingLabelWithString: "")

    init(settings: TouchUpSettings) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func summary(of settings: TouchUpSettings) -> String {
        "light \(percent(settings.light)) · warmth \(signedPercent(settings.warmth)) · smooth \(percent(settings.smooth))"
    }

    var reportDescription: String {
        "on=\(settings.enabled) light=\(lightValue.stringValue) warmth=\(warmthValue.stringValue) smooth=\(smoothValue.stringValue) switchEnabled=\(enabledSwitch.isEnabled) slidersEnabled=\(lightSlider.isEnabled) resetEnabled=\(resetButton.isEnabled) available=\(isAvailable)"
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "Touch-up")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        enabledSwitch.target = self
        enabledSwitch.action = #selector(switchChanged)
        enabledSwitch.controlSize = .small
        let header = NSStackView(views: [title, NSView(), enabledSwitch])
        header.orientation = .horizontal
        header.alignment = .centerY

        let subtitle = NSTextField(labelWithString: "Camera only · the preview is the recording")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        for slider in [lightSlider, warmthSlider, smoothSlider] {
            slider.target = self
            slider.action = #selector(sliderChanged)
            slider.isContinuous = true
            slider.controlSize = .small
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 156).isActive = true
        }
        // Warmth runs both ways from the camera's own white balance; the
        // middle tick is "as the camera sees it".
        warmthSlider.numberOfTickMarks = 3
        warmthSlider.allowsTickMarkValuesOnly = false
        lightSlider.toolTip = "Fill light · lifts shadows and midtones, leaves highlights alone"
        warmthSlider.toolTip = "Cooler ← → warmer · centre is the camera's own white balance"
        smoothSlider.toolTip = "Evens out skin inside the detected face · eyes, brows, lips and hair stay sharp · no face, no smoothing"

        let grid = NSGridView(views: [
            [Self.rowLabel("LIGHT", symbol: "sun.max"), lightSlider, lightValue],
            [Self.rowLabel("WARMTH", symbol: "thermometer.medium"), warmthSlider, warmthValue],
            [Self.rowLabel("SMOOTH", symbol: "sparkles"), smoothSlider, smoothValue]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 2).xPlacement = .trailing
        for index in 0..<grid.numberOfRows { grid.row(at: index).yPlacement = .center }

        resetButton.target = self
        resetButton.action = #selector(reset)
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.font = .systemFont(ofSize: 11)
        resetButton.toolTip = "Back to the default touch-up"
        footnote.font = .systemFont(ofSize: 10.5)
        footnote.textColor = .tertiaryLabelColor
        footnote.preferredMaxLayoutWidth = 200
        footnote.stringValue = "Smoothing follows your face. No reshaping."
        let footer = NSStackView(views: [resetButton, footnote])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10

        let stack = NSStackView(views: [header, subtitle, grid, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: header)
        stack.setCustomSpacing(14, after: subtitle)
        stack.setCustomSpacing(14, after: grid)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 300)
        ])
        view = root
        showSettings()
    }

    func show(_ newSettings: TouchUpSettings) {
        settings = newSettings
        if isViewLoaded { showSettings() }
    }

    private func showSettings() {
        enabledSwitch.state = settings.enabled ? .on : .off
        lightSlider.doubleValue = settings.light
        warmthSlider.doubleValue = settings.warmth
        smoothSlider.doubleValue = settings.smooth
        updateValues()
        updateEnabled()
    }

    private func updateValues() {
        lightValue.stringValue = Self.percent(settings.light)
        warmthValue.stringValue = Self.signedPercent(settings.warmth)
        smoothValue.stringValue = Self.percent(settings.smooth)
    }

    private func updateEnabled() {
        guard isViewLoaded else { return }
        enabledSwitch.isEnabled = isEditable && isAvailable
        let sliders = isEditable && isAvailable && settings.enabled
        for slider in [lightSlider, warmthSlider, smoothSlider] { slider.isEnabled = sliders }
        resetButton.isEnabled = isEditable && isAvailable
        for label in [lightValue, warmthValue, smoothValue] {
            label.textColor = sliders ? .secondaryLabelColor : .tertiaryLabelColor
        }
        if !isAvailable {
            footnote.stringValue = "Unavailable: this Mac's GPU cannot run the touch-up filters."
        }
    }

    @objc private func switchChanged() {
        settings.enabled = enabledSwitch.state == .on
        updateEnabled()
        onChange?(settings)
    }

    @objc private func sliderChanged() {
        settings.light = lightSlider.doubleValue
        // A small dead zone around the centre tick, so "neutral" is easy to hit.
        let warmth = warmthSlider.doubleValue
        settings.warmth = abs(warmth) < 0.04 ? 0 : warmth
        settings.smooth = smoothSlider.doubleValue
        updateValues()
        onChange?(settings)
    }

    @objc private func reset() {
        let enabled = settings.enabled
        settings = .defaults
        settings.enabled = enabled
        showSettings()
        onChange?(settings)
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.0f", (value * 100).rounded())
    }

    private static func signedPercent(_ value: Double) -> String {
        let rounded = Int((value * 100).rounded())
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }

    private static func valueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "0")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 32).isActive = true
        return label
    }

    private static func rowLabel(_ title: String, symbol: String) -> NSView {
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = .secondaryLabelColor
        image.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        let row = NSStackView(views: [image, label])
        row.orientation = .horizontal
        row.spacing = 5
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 72).isActive = true
        return row
    }
}
