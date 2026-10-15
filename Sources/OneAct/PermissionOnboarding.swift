import AppKit
import AVFoundation

@MainActor
final class PermissionOnboardingController {
    let window: NSWindow

    private let cameraStatus = NSTextField(labelWithString: "")
    private let microphoneStatus = NSTextField(labelWithString: "")
    private let cameraButton = NSButton(title: "", target: nil, action: nil)
    private let microphoneButton = NSButton(title: "", target: nil, action: nil)
    private let footer = NSTextField(labelWithString: "")
    private let onAuthorized: () -> Void
    private var didFinish = false

    init(onAuthorized: @escaping () -> Void) {
        self.onAuthorized = onAuthorized
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 410))
        window = NSWindow(
            contentRect: content.bounds,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OneAct Setup"
        window.contentView = content
        window.center()
        window.setContentSize(content.bounds.size)

        let title = NSTextField(labelWithString: "Welcome to OneAct")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        title.alignment = .center

        let subtitle = NSTextField(
            wrappingLabelWithString: "Recording needs both camera and microphone access. Grant them below — the recording interface opens once both are allowed."
        )
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        let cameraRow = permissionRow(
            title: "Camera",
            detail: "Previews and records the Mac or Continuity Camera",
            statusLabel: cameraStatus,
            button: cameraButton
        )
        let microphoneRow = permissionRow(
            title: "Microphone",
            detail: "Records the selected microphone into the movie",
            statusLabel: microphoneStatus,
            button: microphoneButton
        )

        footer.stringValue = "OneAct never changes the macOS default camera or microphone."
        footer.textColor = .tertiaryLabelColor
        footer.font = .systemFont(ofSize: 11)
        footer.alignment = .center

        cameraButton.target = self
        cameraButton.action = #selector(handleCameraPermission)
        microphoneButton.target = self
        microphoneButton.action = #selector(handleMicrophonePermission)

        let stack = NSStackView(views: [title, subtitle, cameraRow, microphoneRow, footer])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 24, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            subtitle.widthAnchor.constraint(equalToConstant: 510),
            cameraRow.widthAnchor.constraint(equalToConstant: 520),
            cameraRow.heightAnchor.constraint(equalToConstant: 92),
            microphoneRow.widthAnchor.constraint(equalToConstant: 520),
            microphoneRow.heightAnchor.constraint(equalToConstant: 92),
            footer.widthAnchor.constraint(equalToConstant: 520)
        ])

        refresh()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }

    func refresh() {
        let camera = AVCaptureDevice.authorizationStatus(for: .video)
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        updateRow(status: camera, mediaType: .video, label: cameraStatus, button: cameraButton)
        updateRow(status: microphone, mediaType: .audio, label: microphoneStatus, button: microphoneButton)

        guard camera == .authorized, microphone == .authorized, !didFinish else { return }
        didFinish = true
        footer.stringValue = "All set — opening the recording interface…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.onAuthorized()
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        statusLabel: NSTextField,
        button: NSButton
    ) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderType = .lineBorder
        box.borderColor = .separatorColor
        box.cornerRadius = 10
        box.fillColor = .controlBackgroundColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        // Text stops at the button rather than running under it, whatever the
        // wording ends up being.
        detailLabel.lineBreakMode = .byTruncatingTail
        titleLabel.lineBreakMode = .byTruncatingTail

        for view in [titleLabel, detailLabel, statusLabel, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(view)
        }
        button.bezelStyle = .rounded

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: box.topAnchor, constant: 13),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 5),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
            button.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            button.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 132)
        ])
        return box
    }

    private func updateRow(
        status: AVAuthorizationStatus,
        mediaType: AVMediaType,
        label: NSTextField,
        button: NSButton
    ) {
        switch status {
        case .authorized:
            label.stringValue = "✓ Allowed"
            label.textColor = .systemGreen
            button.title = "Done"
            button.isEnabled = false
        case .notDetermined:
            label.stringValue = "Not requested yet"
            label.textColor = .secondaryLabelColor
            button.title = mediaType == .video ? "Allow Camera…" : "Allow Microphone…"
            button.isEnabled = true
        case .denied:
            label.stringValue = "Denied"
            label.textColor = .systemRed
            button.title = "Open Settings…"
            button.isEnabled = true
        case .restricted:
            label.stringValue = "Restricted"
            label.textColor = .systemRed
            button.title = "Open Settings…"
            button.isEnabled = true
        @unknown default:
            label.stringValue = "Status unavailable"
            label.textColor = .systemOrange
            button.title = "Refresh"
            button.isEnabled = true
        }
    }

    @objc private func handleCameraPermission() {
        handlePermission(for: .video, button: cameraButton)
    }

    @objc private func handleMicrophonePermission() {
        handlePermission(for: .audio, button: microphoneButton)
    }

    private func handlePermission(for mediaType: AVMediaType, button: NSButton) {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .notDetermined:
            button.isEnabled = false
            button.title = "Waiting…"
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: mediaType) { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        case .denied, .restricted:
            let pane = mediaType == .video ? "Privacy_Camera" : "Privacy_Microphone"
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)"
            ) {
                NSWorkspace.shared.open(url)
            }
        case .authorized:
            refresh()
        @unknown default:
            refresh()
        }
    }
}
