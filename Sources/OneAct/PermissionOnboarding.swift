import AppKit
import AVFoundation
import Speech

@MainActor
final class PermissionOnboardingController {
    let window: NSWindow

    private let cameraStatus = NSTextField(labelWithString: "")
    private let microphoneStatus = NSTextField(labelWithString: "")
    private let cameraButton = NSButton(title: "", target: nil, action: nil)
    private let microphoneButton = NSButton(title: "", target: nil, action: nil)
    private let speechStatus = NSTextField(labelWithString: "")
    private let speechButton = NSButton(title: "", target: nil, action: nil)
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let footer = NSTextField(labelWithString: "")
    private let onAuthorized: () -> Void
    private var didFinish = false

    init(onAuthorized: @escaping () -> Void) {
        self.onAuthorized = onAuthorized
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 560))
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
            wrappingLabelWithString: "Recording needs camera and microphone access. Speech recognition is optional — it lets the teleprompter follow your voice."
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
        // The one permission a presenter can skip, so the row says plainly
        // what it buys, what it costs, and what changes once it is allowed.
        let speechRow = permissionRow(
            title: "Speech Recognition · Optional",
            detail: "For Follow voice: the teleprompter scrolls as you read aloud and waits when you pause or go off script. Recognition runs on this Mac, and audio never leaves it.",
            statusLabel: speechStatus,
            button: speechButton,
            detailLines: 3
        )

        footer.stringValue = "OneAct never changes the macOS default camera or microphone."
        footer.textColor = .tertiaryLabelColor
        footer.font = .systemFont(ofSize: 11)
        footer.alignment = .center

        cameraButton.target = self
        cameraButton.action = #selector(handleCameraPermission)
        microphoneButton.target = self
        microphoneButton.action = #selector(handleMicrophonePermission)
        speechButton.target = self
        speechButton.action = #selector(handleSpeechPermission)
        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"
        continueButton.target = self
        continueButton.action = #selector(continueWithoutSpeech)

        let stack = NSStackView(views: [title, subtitle, cameraRow, microphoneRow, speechRow, continueButton, footer])
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
            speechRow.widthAnchor.constraint(equalToConstant: 520),
            speechRow.heightAnchor.constraint(equalToConstant: 124),
            continueButton.widthAnchor.constraint(equalToConstant: 132),
            footer.widthAnchor.constraint(equalToConstant: 520)
        ])

        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: content.bounds.width, height: stack.fittingSize.height))
        window.center()
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
        let speech = OnDeviceTranscriber.authorizationStatus
        updateSpeechRow(status: speech)

        let required = camera == .authorized && microphone == .authorized
        continueButton.isEnabled = required && !didFinish
        guard required, !didFinish else { return }
        // Opening the interface the moment the required two are allowed would
        // close the window before the optional row could be reached. With
        // speech still unanswered the presenter moves on with Continue; once
        // it has an answer either way, there is nothing left to wait for.
        guard speech != .notDetermined else {
            footer.stringValue = "Speech recognition can also be allowed later, when you turn on Follow voice."
            return
        }
        finish()
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        continueButton.isEnabled = false
        footer.stringValue = "All set — opening the recording interface…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.onAuthorized()
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        statusLabel: NSTextField,
        button: NSButton,
        detailLines: Int = 1
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
        detailLabel.lineBreakMode = detailLines > 1 ? .byWordWrapping : .byTruncatingTail
        detailLabel.maximumNumberOfLines = detailLines
        // Row width less the insets and the button column, so wrapping text
        // knows where to break.
        detailLabel.preferredMaxLayoutWidth = 520 - 16 - 132 - 16 - 12
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

    /// Speech recognition only ever asks when its button is clicked: a prompt
    /// declined in passing could not be shown again, and Follow voice would
    /// then need a trip to System Settings.
    private func updateSpeechRow(status: SFSpeechRecognizerAuthorizationStatus) {
        switch status {
        case .authorized:
            // A presenter who switched Follow voice off keeps it off.
            speechStatus.stringValue = TeleprompterController.followVoiceSwitchedOff
                ? "✓ Allowed"
                : "✓ Allowed · Follow voice is on"
            speechStatus.textColor = .systemGreen
            speechButton.title = "Done"
            speechButton.isEnabled = false
        case .notDetermined:
            speechStatus.stringValue = "Not requested yet · Follow voice turns on once allowed"
            speechStatus.textColor = .secondaryLabelColor
            speechButton.title = "Allow Speech…"
            speechButton.isEnabled = true
        case .denied:
            speechStatus.stringValue = "Not allowed · Follow voice stays off"
            speechStatus.textColor = .secondaryLabelColor
            speechButton.title = "Open Settings…"
            speechButton.isEnabled = true
        case .restricted:
            speechStatus.stringValue = "Restricted on this Mac"
            speechStatus.textColor = .secondaryLabelColor
            speechButton.title = "Open Settings…"
            speechButton.isEnabled = true
        @unknown default:
            speechStatus.stringValue = "Status unavailable"
            speechStatus.textColor = .systemOrange
            speechButton.title = "Refresh"
            speechButton.isEnabled = true
        }
    }

    @objc private func handleSpeechPermission() {
        switch OnDeviceTranscriber.authorizationStatus {
        case .notDetermined:
            speechButton.isEnabled = false
            speechButton.title = "Waiting…"
            NSApp.activate(ignoringOtherApps: true)
            OnDeviceTranscriber.requestAuthorization { [weak self] _ in self?.refresh() }
        case .denied, .restricted:
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_SpeechRecognition"
            ) {
                NSWorkspace.shared.open(url)
            }
        default:
            refresh()
        }
    }

    @objc private func continueWithoutSpeech() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        finish()
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
