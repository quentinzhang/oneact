import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Metal
import Quartz
import Vision

private struct CanvasPreset: Equatable {
    let name: String
    let width: Int
    let height: Int

    var label: String { "\(name)  \(width) × \(height)" }
}

private struct CanvasAspectRatio: Equatable {
    let label: String
    let name: String
    let widthUnits: Int
    let heightUnits: Int
}

private struct CanvasResolution: Equatable {
    let label: String
    let detail: String
    let shortEdge: Int
}

/// Backdrop behind the video on the canvas: the Fit-layout bars and the empty
/// canvas before a screen source is chosen. A small preset set, mirroring the
/// teleprompter's backdrop swatches.
/// Backdrop of the preview stage — the app's own chrome around the canvas. It
/// is never composited into a recording, so a handful of quiet presets is
/// enough; they live behind a hover reveal to stay out of the way.
private struct StageBackdropPreset {
    let name: String
    let color: NSColor

    static let all: [StageBackdropPreset] = [
        StageBackdropPreset(name: "Ink", color: NSColor(calibratedWhite: 0.055, alpha: 1)),
        StageBackdropPreset(name: "Graphite", color: NSColor(calibratedWhite: 0.20, alpha: 1)),
        StageBackdropPreset(
            name: "Slate",
            color: NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.21, alpha: 1)
        ),
        StageBackdropPreset(name: "Bone", color: NSColor(calibratedWhite: 0.88, alpha: 1))
    ]
}

private struct CanvasBackdropPreset {
    let name: String
    let color: NSColor

    var ciColor: CIColor { CIColor(color: color) ?? .black }

    static let all: [CanvasBackdropPreset] = [
        CanvasBackdropPreset(name: "Black", color: .black),
        CanvasBackdropPreset(name: "Graphite", color: NSColor(calibratedWhite: 0.22, alpha: 1)),
        CanvasBackdropPreset(
            name: "Midnight",
            color: NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.30, alpha: 1)
        ),
        CanvasBackdropPreset(name: "White", color: .white)
    ]
}

private enum CanvasOptions {
    // Landscape first: recording a screen is the primary use, and 16:9 is the
    // default canvas. Portrait ratios follow for phone-format output.
    static let ratios = [
        CanvasAspectRatio(label: "16:9", name: "Landscape", widthUnits: 16, heightUnits: 9),
        CanvasAspectRatio(label: "4:3", name: "Classic", widthUnits: 4, heightUnits: 3),
        CanvasAspectRatio(label: "1:1", name: "Square", widthUnits: 1, heightUnits: 1),
        CanvasAspectRatio(label: "9:16", name: "Portrait", widthUnits: 9, heightUnits: 16),
        CanvasAspectRatio(label: "4:5", name: "Social", widthUnits: 4, heightUnits: 5),
        CanvasAspectRatio(label: "3:4", name: "Portrait", widthUnits: 3, heightUnits: 4)
    ]

    static let resolutions = [
        CanvasResolution(label: "720p", detail: "Compact", shortEdge: 720),
        CanvasResolution(label: "1080p", detail: "Standard", shortEdge: 1_080),
        CanvasResolution(label: "1440p", detail: "High", shortEdge: 1_440)
    ]

    static let defaultRatioIndex = 0
    static let defaultResolutionIndex = 1

    static func preset(ratioIndex: Int, resolutionIndex: Int) -> CanvasPreset {
        let ratio = ratios[ratioIndex]
        let resolution = resolutions[resolutionIndex]
        let isLandscape = ratio.widthUnits > ratio.heightUnits
        let rawWidth: Double
        let rawHeight: Double

        if isLandscape {
            rawHeight = Double(resolution.shortEdge)
            rawWidth = rawHeight * Double(ratio.widthUnits) / Double(ratio.heightUnits)
        } else {
            rawWidth = Double(resolution.shortEdge)
            rawHeight = rawWidth * Double(ratio.heightUnits) / Double(ratio.widthUnits)
        }

        func even(_ value: Double) -> Int {
            let rounded = max(2, Int(value.rounded()))
            return rounded.isMultiple(of: 2) ? rounded : rounded + 1
        }

        return CanvasPreset(
            name: "\(ratio.label) \(ratio.name)",
            width: even(rawWidth),
            height: even(rawHeight)
        )
    }

    static var defaultPreset: CanvasPreset {
        preset(
            ratioIndex: defaultRatioIndex,
            resolutionIndex: defaultResolutionIndex
        )
    }
}

private struct RecordingOutcome {
    let url: URL
    let hasAudio: Bool
}

private final class PreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    private let screenPreviewLayer = AVSampleBufferDisplayLayer()
    private var softwareZoom: CGFloat = 1
    private var captureMode: CaptureMode = .cameraOnly
    private var composedCameraPreview = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
        screenPreviewLayer.videoGravity = .resizeAspect
        screenPreviewLayer.backgroundColor = NSColor.black.cgColor
        screenPreviewLayer.isHidden = true
        layer?.addSublayer(screenPreviewLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.setAffineTransform(.identity)
        previewLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        previewLayer.setAffineTransform(CGAffineTransform(scaleX: softwareZoom, y: softwareZoom))
        screenPreviewLayer.frame = bounds
        CATransaction.commit()
    }

    func setSoftwareZoom(_ zoom: CGFloat) {
        softwareZoom = SoftwareZoom.clamp(zoom)
        needsLayout = true
    }

    func setCaptureMode(_ mode: CaptureMode) {
        captureMode = mode
        window?.invalidateCursorRects(for: self)
        previewLayer.isHidden = mode == .screenAndCamera
        screenPreviewLayer.isHidden = mode == .cameraOnly
        if mode == .cameraOnly {
            screenPreviewLayer.sampleBufferRenderer.flush()
        }
    }

    /// Drag callbacks in normalised canvas coordinates (0…1, origin bottom-left,
    /// matching Core Image) so the caller can work in canvas pixels.
    var onDragBegan: ((CGPoint) -> Void)?
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    // The window is movable by background drag; without this a drag inside the
    // preview would move the window instead of the camera overlay.
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard captureMode == .screenAndCamera else { return }
        onDragBegan?(normalisedPoint(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard captureMode == .screenAndCamera else { return }
        onDragMoved?(normalisedPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        guard captureMode == .screenAndCamera else { return }
        onDragEnded?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if captureMode == .screenAndCamera {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    private func normalisedPoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(
            x: min(max(point.x / bounds.width, 0), 1),
            y: min(max(point.y / bounds.height, 0), 1)
        )
    }

    /// Touch-up changes the camera picture, which the live capture layer
    /// cannot show. While it is on, camera mode previews the composed frames
    /// instead — the ones being recorded. Switching on waits for the first of
    /// them, so the live picture is never swapped for an empty layer.
    func setComposedCameraPreview(_ composed: Bool) {
        guard composed != composedCameraPreview else { return }
        composedCameraPreview = composed
        guard !composed, captureMode == .cameraOnly else { return }
        previewLayer.isHidden = false
        screenPreviewLayer.isHidden = true
        screenPreviewLayer.sampleBufferRenderer.flush()
    }

    func displayComposedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard captureMode == .screenAndCamera || composedCameraPreview else { return }
        let renderer = screenPreviewLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }
        renderer.enqueue(sampleBuffer)
        if captureMode == .cameraOnly, screenPreviewLayer.isHidden {
            screenPreviewLayer.isHidden = false
            previewLayer.isHidden = true
        }
    }
}

private final class SurfaceView: NSView {
    enum Style {
        case previewStage
        case controls
    }

    private let style: Style
    private var trackingArea: NSTrackingArea?
    private var customBackground: NSColor?
    /// Reports pointer enter/exit so the stage can reveal its backdrop dots only
    /// when the user is actually looking at it.
    var onHoverChanged: ((Bool) -> Void)?

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = style == .previewStage ? 18 : 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    func setBackdropColor(_ color: NSColor) {
        customBackground = color
        updateAppearance()
    }

    private func updateAppearance() {
        switch style {
        case .previewStage:
            layer?.backgroundColor =
                (customBackground ?? NSColor(calibratedWhite: 0.055, alpha: 1)).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        case .controls:
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        }
    }
}

private final class PrimaryRecordButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        font = .systemFont(ofSize: 14, weight: .semibold)
        contentTintColor = .white
        layer?.cornerRadius = 19
        layer?.cornerCurve = .continuous
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    private var isRecordingAppearance = false

    /// Whether ⌥⌘R also works from other apps. It always works while OneAct
    /// is in front, through the Recording menu.
    var shortcutIsGlobal = true {
        didSet { refreshTitle() }
    }

    private func refreshTitle() {
        title = isRecordingAppearance ? "■  Stop" : "●  Record"
        let action = isRecordingAppearance ? "Stop recording" : "Start recording"
        toolTip = shortcutIsGlobal ? "\(action) (⌥⌘R, from any app)" : "\(action) (⌥⌘R)"
    }

    func setRecordingAppearance(_ recording: Bool) {
        isRecordingAppearance = recording
        refreshTitle()
        layer?.removeAnimation(forKey: "recordingPulse")
        layer?.backgroundColor = NSColor.systemRed.cgColor
        guard recording else { return }
        // A breathing red is unmistakable from across the room, where a slightly
        // different shade of the same button is not.
        let pulse = CABasicAnimation(keyPath: "backgroundColor")
        pulse.fromValue = NSColor.systemRed.cgColor
        pulse.toValue = NSColor(calibratedRed: 0.42, green: 0.04, blue: 0.08, alpha: 1).cgColor
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(pulse, forKey: "recordingPulse")
    }

    /// A paused take is still a take, so the button stays Stop — but the
    /// breathing has to end. Left running it would claim frames are being
    /// written when none are.
    func setPausedAppearance(_ paused: Bool) {
        guard isRecordingAppearance else { return }
        if paused {
            layer?.removeAnimation(forKey: "recordingPulse")
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.55).cgColor
        } else {
            setRecordingAppearance(true)
        }
    }

    private func updateAppearance() {
        alphaValue = isEnabled ? 1 : 0.45
        if layer?.backgroundColor == nil {
            layer?.backgroundColor = NSColor.systemRed.cgColor
        }
    }
}

private final class CanvasPresetButton: NSButton {
    let presetIndex: Int
    private var selected = false

    init(presetIndex: Int, title: String) {
        self.presetIndex = presetIndex
        super.init(frame: .zero)
        self.title = title
        wantsLayer = true
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        font = .systemFont(ofSize: 11, weight: .medium)
        alignment = .center
        lineBreakMode = .byClipping
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.45 }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func setSelected(_ selected: Bool) {
        self.selected = selected
        updateAppearance()
    }

    private func updateAppearance() {
        if selected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            contentTintColor = .white
        } else {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.82).cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.72).cgColor
            contentTintColor = .labelColor
        }
    }
}

private final class Recorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let previewLayer: AVCaptureVideoPreviewLayer

    private let captureQueue = DispatchQueue(label: "oneact.capture")
    private let segmentationQueue = DispatchQueue(label: "oneact.segmentation")
    private let maskLock = NSLock()
    private let ciContext: CIContext
    /// Light, warmth and skin smoothing for the camera layer only.
    let touchUp: TouchUpStage
    private let canvasLock = NSLock()
    private var canvas = CanvasOptions.defaultPreset
    private var softwareZoom: CGFloat = 1
    private var captureMode: CaptureMode = .cameraOnly
    private var pictureInPicturePosition: PictureInPicturePosition = .bottomRight
    private var screenLayoutMode: ScreenLayoutMode = .blur
    private var screenVerticalAlignment: ScreenVerticalAlignment = .center
    private var cameraFrameStyle: CameraFrameStyle = .rectangle
    private var cameraOrigin: CGPoint?
    private var cameraOverlayScale: CGFloat = 1
    private var cameraMirrored = false
    private var mirrorInCompositor = false
    private var screenCropOffset: CGPoint = .zero
    private var screenSourceActive = false
    private var canvasBackdrop: CIColor = .black
    /// The format the camera was actually put on, so the interface can say so.
    /// A resolution the user cannot see is a resolution nobody notices going
    /// wrong — this whole class of bug hid behind that.
    private(set) var activeCameraFormat: CameraFormatCandidate? {
        didSet {
            guard activeCameraFormat != oldValue else { return }
            onCameraFormatChange?(activeCameraFormat)
        }
    }
    /// Fires on the main queue when the camera lands on a different format,
    /// which a canvas change can do without any other visible event. Without
    /// it the resolution on screen is right only until the first ratio click.
    var onCameraFormatChange: ((CameraFormatCandidate?) -> Void)?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var writer: AVAssetWriter?
    private var writerVideoInput: AVAssetWriterInput?
    private var writerAudioInput: AVAssetWriterInput?
    private var recordingFormat: VideoRecordingFormat = .h264
    private var pixelBufferPool: CVPixelBufferPool?
    private var screenPixelBufferPool: CVPixelBufferPool?
    private var latestCameraBuffer: CVPixelBuffer?
    private var latestPersonMask: CIImage?
    private var personTracker = PersonBoxTracker()
    private var segmentationInFlight = false
    private var didReportSegmentationFailure = false
    private lazy var segmentationRequest: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private var recording = false
    /// Main-thread flag mirrored into the mixer; read by the start guard.
    private var microphoneIntentionallyDisabled = false
    private let audioMixer = AudioMixer()
    private var pauseClock = PauseClock()
    private var lastWrittenVideoTime: CMTime = .invalid
    private var didStartSession = false
    private var writerSessionStartTime = CMTime.invalid
    private var didAppendAudioSample = false
    var onScreenPreviewFrame: ((CMSampleBuffer) -> Void)?
    var onPersonSegmentationFailure: ((Error) -> Void)?
    /// Input level in dBFS for the meter, delivered on the main queue. Reported
    /// whenever the session is running, not just while recording — the point of
    /// the meter is to catch a dead microphone before the take, not after.
    var onAudioLevel: ((Float) -> Void)?
    private var lastAudioLevelReport: CFTimeInterval = 0
    /// Every microphone buffer, recording or not, on the capture queue — for
    /// listeners such as the teleprompter's Follow voice, which must not open
    /// a second capture session on the same device.
    private var microphoneSampleHandler: ((CMSampleBuffer) -> Void)?
    private let usesNativeCameraFormat: Bool
    private var frameDiagnostics: CameraFrameDiagnostics?
    private var lastCaptureState: CameraCaptureState?
    private var lastCaptureStateTime: CFTimeInterval = 0
    var onCaptureStateChange: ((CameraCaptureState) -> Void)?
    var onRecordingCanvasChange: ((CanvasPreset) -> Void)?

    func setFrameDiagnostics(_ diagnostics: CameraFrameDiagnostics?) {
        captureQueue.async { self.frameDiagnostics = diagnostics }
    }

    func setMicrophoneSampleHandler(_ handler: ((CMSampleBuffer) -> Void)?) {
        captureQueue.async { self.microphoneSampleHandler = handler }
    }

    func setRecordingFormat(_ format: VideoRecordingFormat) {
        captureQueue.async {
            guard !self.recording, self.writer == nil else { return }
            self.recordingFormat = format
        }
    }

    init(previewLayer: AVCaptureVideoPreviewLayer, usesNativeCameraFormat: Bool = true) {
        self.previewLayer = previewLayer
        self.usesNativeCameraFormat = usesNativeCameraFormat
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: metalDevice)
        } else {
            ciContext = CIContext(options: [.useSoftwareRenderer: true])
        }
        touchUp = TouchUpStage(context: ciContext)
        super.init()
        audioMixer.onMixedBuffer = { [weak self] sampleBuffer in
            self?.appendMixedAudio(sampleBuffer)
        }
        screenPixelBufferPool = Self.makePixelBufferPool(
            width: CanvasOptions.defaultPreset.width,
            height: CanvasOptions.defaultPreset.height
        )
        previewLayer.session = session
    }

    var isRecording: Bool {
        captureQueue.sync { recording }
    }

    var isPaused: Bool {
        captureQueue.sync { pauseClock.isPaused }
    }

    /// Stop writing without closing the file. Both modes go through the same
    /// switch because both feed one writer: only the source of the video track
    /// differs, and the audio track is shared.
    func pauseRecording() {
        captureQueue.async {
            guard self.recording, !self.pauseClock.isPaused else { return }
            self.pauseClock.pause()
        }
    }

    func resumeRecording() {
        captureQueue.async {
            guard self.recording, self.pauseClock.isPaused else { return }
            self.pauseClock.resume()
        }
    }

    func setCanvas(_ newCanvas: CanvasPreset) {
        canvasLock.lock()
        canvas = newCanvas
        screenPixelBufferPool = Self.makePixelBufferPool(
            width: newCanvas.width,
            height: newCanvas.height
        )
        canvasLock.unlock()

        // Which camera format fits best is a question about the canvas ratio,
        // so it has to be asked again every time that ratio moves. Never
        // mid-take: swapping `activeFormat` interrupts the stream, and the
        // canvas controls are locked while a recording is open anyway.
        captureQueue.async { [weak self] in self?.applyCameraFormat() }
    }

    /// On macOS, committing the session's high preset can overwrite an active
    /// format selected inside begin/commitConfiguration. Apply after the graph
    /// has committed and started, and read recording/device state on its queue.
    private func applyCameraFormat() {
        guard usesNativeCameraFormat, !recording, session.isRunning,
              let device = videoInput?.device else { return }
        canvasLock.lock()
        let selectedCanvas = canvas
        canvasLock.unlock()
        let applied = CameraFormatSelection.apply(
            canvasWidth: selectedCanvas.width,
            canvasHeight: selectedCanvas.height,
            to: device
        )
        DispatchQueue.main.async { [weak self] in self?.activeCameraFormat = applied }
    }

    func setSoftwareZoom(_ zoom: CGFloat) {
        canvasLock.lock()
        softwareZoom = SoftwareZoom.clamp(zoom)
        canvasLock.unlock()
    }

    func setCaptureMode(_ mode: CaptureMode) {
        canvasLock.lock()
        captureMode = mode
        canvasLock.unlock()
        applyVideoMirroring()
    }

    func setCameraMirrored(_ mirrored: Bool) {
        canvasLock.lock()
        cameraMirrored = mirrored
        canvasLock.unlock()
        applyVideoMirroring()
        // The person's smoothed box belongs to the old handedness; easing across
        // the flip would drag them over the canvas for a second afterwards.
        maskLock.lock()
        personTracker.reset()
        maskLock.unlock()
        touchUp.faceTracker.reset()
    }

    /// Mirroring is applied at the capture connection so that everything
    /// downstream sees the same picture: the segmentation mask, the composite
    /// and the recording all flip together, with no coordinates to convert.
    ///
    /// It is a Screen + Camera decision. A flip only means anything when the
    /// person sits beside other content, and leaving it switched on invisibly
    /// in camera-only mode would mirror a recording with nothing on screen to
    /// explain why — so the mode gates it while the preference is kept.
    private func applyVideoMirroring() {
        canvasLock.lock()
        let wanted = cameraMirrored && captureMode == .screenAndCamera
        canvasLock.unlock()

        var handledByConnection = false
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = wanted
            handledByConnection = true
        }

        canvasLock.lock()
        mirrorInCompositor = wanted && !handledByConnection
        canvasLock.unlock()
    }

    func setPictureInPicturePosition(_ position: PictureInPicturePosition) {
        canvasLock.lock()
        pictureInPicturePosition = position
        canvasLock.unlock()
    }

    func setScreenLayoutMode(_ mode: ScreenLayoutMode) {
        canvasLock.lock()
        screenLayoutMode = mode
        canvasLock.unlock()
    }

    func setScreenVerticalAlignment(_ alignment: ScreenVerticalAlignment) {
        canvasLock.lock()
        screenVerticalAlignment = alignment
        canvasLock.unlock()
    }

    /// Dragged position of the camera overlay in canvas pixels; nil snaps it
    /// back to the selected corner.
    func setCameraOrigin(_ origin: CGPoint?) {
        canvasLock.lock()
        cameraOrigin = origin
        canvasLock.unlock()
    }

    func setCameraOverlayScale(_ scale: CGFloat) {
        canvasLock.lock()
        cameraOverlayScale = CameraOverlayScale.clamp(scale)
        canvasLock.unlock()
    }

    func setScreenCropOffset(_ offset: CGPoint) {
        canvasLock.lock()
        screenCropOffset = offset
        canvasLock.unlock()
    }

    func setCanvasBackdrop(_ color: CIColor) {
        canvasLock.lock()
        canvasBackdrop = color
        canvasLock.unlock()
    }

    func setScreenSourceActive(_ active: Bool) {
        canvasLock.lock()
        screenSourceActive = active
        canvasLock.unlock()
    }

    func setCameraFrameStyle(_ style: CameraFrameStyle) {
        canvasLock.lock()
        cameraFrameStyle = style
        canvasLock.unlock()
        maskLock.lock()
        latestPersonMask = nil
        // Coming back to a cutout should re-find the person from scratch rather
        // than easing over from wherever they stood minutes ago.
        personTracker.reset()
        maskLock.unlock()
    }

    /// What the cutout layout is currently aiming at: the camera frame it is
    /// placing and the person's smoothed box inside it. The interface needs
    /// both to work out where the person landed on the canvas — a cutout has no
    /// frame, so the person is the only thing there is to hit-test or grab.
    func currentCutoutAnchor() -> (cameraExtent: CGRect, personBox: CGRect)? {
        guard let buffer = latestCameraBuffer else { return nil }
        maskLock.lock()
        let tracked = personTracker.box
        maskLock.unlock()
        canvasLock.lock()
        let flipped = mirrorInCompositor
        canvasLock.unlock()
        // Same flip the compositor applies, or the grab area would sit on the
        // side of the canvas the person just left.
        guard let box = flipped ? tracked.map(FrameCompositor.mirroredHorizontally) : tracked else {
            return nil
        }
        return (
            CGRect(
                x: 0,
                y: 0,
                width: CGFloat(CVPixelBufferGetWidth(buffer)),
                height: CGFloat(CVPixelBufferGetHeight(buffer))
            ),
            box
        )
    }

    func handleScreenSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        captureQueue.async { [weak self] in
            self?.processScreenSampleBuffer(sampleBuffer)
        }
    }

    /// System audio from the screen stream, mixed with the microphone on the
    /// capture queue — the mixer is not thread-safe and never needs to be.
    func handleAppAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        captureQueue.async { [weak self] in
            self?.audioMixer.addSystemAudio(sampleBuffer)
        }
    }

    var isSystemAudioEnabled: Bool {
        captureQueue.sync { audioMixer.systemAudioEnabled }
    }

    func setSystemAudioEnabled(_ enabled: Bool) {
        captureQueue.async { self.audioMixer.setSystemAudioEnabled(enabled) }
    }

    /// Intentionally recording without a microphone is a different state from
    /// a microphone that failed: recording is allowed, the mixer becomes
    /// system-driven, and a file without speech is a success, not a warning.
    func setMicrophoneIntentionallyDisabled(_ disabled: Bool) {
        captureQueue.async { self.audioMixer.microphonePresent = !disabled }
        microphoneIntentionallyDisabled = disabled
    }

    func configure(videoDevice: AVCaptureDevice, audioDevice: AVCaptureDevice?) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let videoInput { session.removeInput(videoInput) }
        if let audioInput { session.removeInput(audioInput) }
        videoInput = nil
        audioInput = nil

        let newVideoInput = try AVCaptureDeviceInput(device: videoDevice)
        guard session.canAddInput(newVideoInput) else { throw RecorderError.cannotAddVideoInput }
        session.addInput(newVideoInput)
        videoInput = newVideoInput

        if let audioDevice {
            let newAudioInput = try AVCaptureDeviceInput(device: audioDevice)
            guard session.canAddInput(newAudioInput) else { throw RecorderError.cannotAddAudioInput }
            session.addInput(newAudioInput)
            audioInput = newAudioInput
        }

        if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
            session.addOutput(videoOutput)
        }

        if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
            audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
            session.addOutput(audioOutput)
        }

        // A new device brings a new connection, which starts out with whatever
        // mirroring AVFoundation thinks the device wants.
        applyVideoMirroring()
        touchUp.faceTracker.reset()
    }

    func startSession() {
        captureQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
            self.applyCameraFormat()
        }
    }

    func startSession(completion: @escaping (Bool) -> Void) {
        captureQueue.async {
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.applyCameraFormat()
            let isRunning = self.session.isRunning
            DispatchQueue.main.async {
                completion(isRunning)
            }
        }
    }

    func startRecording(to url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let microphoneOptional = microphoneIntentionallyDisabled
        captureQueue.async {
            do {
                try self.beginWriter(url: url, microphoneOptional: microphoneOptional)
                self.recording = true
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func stopRecording(completion: @escaping (Result<RecordingOutcome, Error>) -> Void) {
        captureQueue.async {
            guard self.recording, let writer = self.writer else { return }
            self.recording = false
            // Stopping from a paused state still closes the file normally; the
            // flag must not survive into the next take's UI.
            self.pauseClock.resume()
            self.writerVideoInput?.markAsFinished()
            self.writerAudioInput?.markAsFinished()
            let url = writer.outputURL
            writer.finishWriting {
                let result: Result<RecordingOutcome, Error>
                if writer.status == .completed {
                    result = .success(RecordingOutcome(url: url, hasAudio: self.didAppendAudioSample))
                } else {
                    result = .failure(writer.error ?? RecorderError.writerFailed)
                }
                self.writer = nil
                self.writerVideoInput = nil
                self.writerAudioInput = nil
                self.pixelBufferPool = nil
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private func beginWriter(url: URL, microphoneOptional: Bool) throws {
        canvasLock.lock()
        var selectedCanvas = canvas
        let selectedMode = captureMode
        let selectedZoom = softwareZoom
        canvasLock.unlock()

        // Enforce the limit on the capture queue using a delivered frame. The
        // UI can still be catching up with a device, ratio, or zoom change.
        if selectedMode == .cameraOnly {
            guard let source = latestCameraBuffer else { throw RecorderError.cameraFrameUnavailable }
            let size = CameraOutputSizing.limited(
                width: selectedCanvas.width, height: selectedCanvas.height,
                sourceWidth: CVPixelBufferGetWidth(source), sourceHeight: CVPixelBufferGetHeight(source),
                zoom: selectedZoom
            )
            selectedCanvas = CanvasPreset(name: selectedCanvas.name, width: size.width, height: size.height)
            canvasLock.lock()
            canvas = selectedCanvas
            screenPixelBufferPool = Self.makePixelBufferPool(width: size.width, height: size.height)
            canvasLock.unlock()
        }

        let newWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoSettings = VideoEncoding.writerSettings(
            width: selectedCanvas.width, height: selectedCanvas.height, format: recordingFormat
        )
        guard newWriter.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw RecorderError.unsupportedRecordingFormat(recordingFormat.label)
        }
        let newVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        newVideoInput.expectsMediaDataInRealTime = true
        guard newWriter.canAdd(newVideoInput) else { throw RecorderError.cannotAddWriterInput }
        newWriter.add(newVideoInput)

        // A missing microphone is only an error when one was expected. The
        // audio input is added either way: system audio can be switched on
        // mid-take, and an input that never receives a sample is dropped from
        // the finished file entirely rather than leaving an empty track.
        guard audioInput != nil || microphoneOptional else {
            throw RecorderError.microphoneUnavailable
        }
        let fallbackAudioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ]
        // The track encodes the mixer's canonical output — 48kHz stereo — no
        // matter which microphone feeds it, so toggling system audio mid-take
        // can never change the stream's shape under the encoder.
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]
        let newAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        newAudioInput.expectsMediaDataInRealTime = true
        guard newWriter.canAdd(newAudioInput) else { throw RecorderError.cannotAddAudioWriterInput }
        newWriter.add(newAudioInput)

        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: selectedCanvas.width,
            kCVPixelBufferHeightKey as String: selectedCanvas.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)

        writer = newWriter
        writerVideoInput = newVideoInput
        writerAudioInput = newAudioInput
        pixelBufferPool = pool
        didStartSession = false
        writerSessionStartTime = .invalid
        didAppendAudioSample = false
        lastWrittenVideoTime = .invalid
        pauseClock.reset()
        let recordingCanvas = selectedCanvas
        DispatchQueue.main.async { self.onRecordingCanvasChange?(recordingCanvas) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            latestCameraBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            let now = CACurrentMediaTime()
            if let buffer = latestCameraBuffer, let device = videoInput?.device,
               now - lastCaptureStateTime >= 0.5 {
                lastCaptureStateTime = now
                let state = CameraCaptureState(buffer: buffer, device: device)
                if state != lastCaptureState {
                    lastCaptureState = state
                    DispatchQueue.main.async { self.onCaptureStateChange?(state) }
                }
            }
            canvasLock.lock()
            let selectedMode = captureMode
            let selectedFrame = cameraFrameStyle
            canvasLock.unlock()
            if let cameraBuffer = latestCameraBuffer,
               selectedMode == .cameraOnly || selectedFrame.showsCamera {
                touchUp.observe(cameraBuffer)
            }
            if selectedMode == .screenAndCamera {
                if selectedFrame.needsPersonMask, let cameraBuffer = latestCameraBuffer {
                    requestPersonMask(for: cameraBuffer)
                }
                // Before a screen source is chosen there are no screen frames to
                // drive the preview, so the camera is composited onto an empty
                // canvas: the overlay is visible and can already be positioned.
                canvasLock.lock()
                let sourceActive = screenSourceActive
                canvasLock.unlock()
                if !sourceActive {
                    renderEmptyCanvasPreview(timingFrom: sampleBuffer)
                }
            }
            let touchedUpFrame = selectedMode == .cameraOnly && touchUp.isActive
                ? composedCameraPreview(from: sampleBuffer)
                : nil
            guard selectedMode == .cameraOnly,
                  recording,
                  let writerClockTime = writerTime(for: sampleBuffer),
                  startWriterIfNeeded(at: writerClockTime) else { return }
            guard let writerVideoInput, writerVideoInput.isReadyForMoreMediaData,
                  let transformedBuffer = touchedUpFrame ?? makeCanvasBuffer(from: sampleBuffer),
                  let timedBuffer = retimed(transformedBuffer) else { return }
            if appendVideo(timedBuffer, to: writerVideoInput), let device = videoInput?.device {
                frameDiagnostics?.inspect(
                    source: sampleBuffer,
                    output: timedBuffer,
                    sessionStartTime: writerSessionStartTime,
                    device: device,
                    sessionPreset: session.sessionPreset,
                    videoSettings: videoOutput.videoSettings ?? [:]
                )
            }
        } else if output === audioOutput {
            reportAudioLevel(from: connection)
            microphoneSampleHandler?(sampleBuffer)
            audioMixer.addMicrophone(sampleBuffer)
        }
    }

    /// Mixed audio (or plain converted microphone when system audio is off),
    /// on the capture queue. From here the buffer is treated exactly as mic
    /// audio always was — pause clock, retiming, then the writer.
    private func appendMixedAudio(_ sampleBuffer: CMSampleBuffer) {
        guard recording,
              let writerClockTime = writerTime(for: sampleBuffer),
              startWriterIfNeeded(at: writerClockTime),
              let writerAudioInput, writerAudioInput.isReadyForMoreMediaData,
              let timedBuffer = retimed(sampleBuffer) else { return }
        if writerAudioInput.append(timedBuffer) {
            didAppendAudioSample = true
        }
    }

    /// Audio buffers arrive far faster than anything worth redrawing, so the
    /// meter is fed at display rate. AVFoundation keeps the per-channel average
    /// for us; taking the loudest channel means a mono mic wired to one side of
    /// a stereo input still moves the bar.
    private func reportAudioLevel(from connection: AVCaptureConnection) {
        guard let onAudioLevel else { return }
        let now = CACurrentMediaTime()
        guard now - lastAudioLevelReport >= 1.0 / 30.0 else { return }
        lastAudioLevelReport = now
        guard let loudest = connection.audioChannels.map(\.averagePowerLevel).max() else { return }
        DispatchQueue.main.async { onAudioLevel(loudest) }
    }

    /// The writer-clock timestamp for a sample, or nil when the sample belongs
    /// to a paused stretch and must be dropped.
    ///
    /// Called once per sample on whichever track is being written, so the two
    /// modes and the audio track share one pause bookkeeping. Screen frames,
    /// camera frames and audio all ride the same host clock, so whichever track
    /// delivers first after a resume closes the gap for every track at once.
    private func writerTime(for sampleBuffer: CMSampleBuffer) -> CMTime? {
        pauseClock.writerTime(for: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    /// Writer-clock timing for a sample. Nothing needs rewriting until a pause
    /// has actually happened, which is the common case: the buffer goes through
    /// untouched and costs nothing.
    private func retimed(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard pauseClock.skipped > .zero else { return sampleBuffer }
        return retimedSampleBuffer(sampleBuffer, offsetBy: pauseClock.skipped)
    }

    /// Appends a video frame, dropping anything that would move the track's
    /// timeline backwards.
    ///
    /// One video track is now fed from three places — camera frames in camera
    /// mode, composed screen frames, and the bare canvas when no screen source
    /// is selected — and they carry independent clocks. Switching mode or
    /// picking a source mid-take hands over between them, and the incoming
    /// stream's first frame can be stamped fractionally before the outgoing
    /// stream's last. AVAssetWriter rejects a frame that is not strictly later
    /// and fails the whole recording, so the overlap is dropped instead.
    @discardableResult
    private func appendVideo(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput) -> Bool {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid else { return false }
        if lastWrittenVideoTime.isValid, presentationTime <= lastWrittenVideoTime { return false }
        guard input.append(sampleBuffer) else { return false }
        lastWrittenVideoTime = presentationTime
        return true
    }

    private func startWriterIfNeeded(at presentationTime: CMTime) -> Bool {
        guard let writer else { return false }
        if writer.status == .unknown {
            guard writer.startWriting() else { return false }
            writer.startSession(atSourceTime: presentationTime)
            writerSessionStartTime = presentationTime
            didStartSession = true
        }
        return writer.status == .writing && didStartSession
    }

    private func processScreenSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        canvasLock.lock()
        let selectedMode = captureMode
        let selectedCanvas = canvas
        let selectedZoom = softwareZoom
        let selectedPosition = pictureInPicturePosition
        let selectedScreenLayout = screenLayoutMode
        let selectedScreenAlignment = screenVerticalAlignment
        let selectedCameraFrame = cameraFrameStyle
        let selectedCameraOrigin = cameraOrigin
        let selectedCameraScale = cameraOverlayScale
        let selectedScreenCropOffset = screenCropOffset
        let selectedBackdrop = canvasBackdrop
        let selectedMirrorInCompositor = mirrorInCompositor
        let pool = screenPixelBufferPool
        canvasLock.unlock()

        guard selectedMode == .screenAndCamera,
              let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let pool else { return }

        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
              let destination else { return }

        let cameraLayer = composedCameraLayer(
            style: selectedCameraFrame,
            mirrorInCompositor: selectedMirrorInCompositor
        )
        let outputImage = FrameCompositor.screenWithCamera(
            screen: CIImage(cvPixelBuffer: sourceBuffer),
            camera: cameraLayer?.image,
            width: selectedCanvas.width,
            height: selectedCanvas.height,
            cameraZoom: selectedZoom,
            position: selectedPosition,
            screenLayout: selectedScreenLayout,
            verticalAlignment: selectedScreenAlignment,
            cameraFrame: selectedCameraFrame,
            cameraOrigin: selectedCameraOrigin,
            cameraScale: selectedCameraScale,
            screenCropOffset: selectedScreenCropOffset,
            canvasBackground: selectedBackdrop,
            personBox: cameraLayer?.personBox
        )
        VideoEncoding.render(outputImage, to: destination, using: ciContext)

        guard let composedSample = makeSampleBuffer(
            pixelBuffer: destination,
            timingFrom: sampleBuffer
        ) else { return }

        CMSetAttachment(
            composedSample,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate
        )
        DispatchQueue.main.async { [weak self] in
            self?.onScreenPreviewFrame?(composedSample)
        }

        // The preview above keeps running while paused; only the writer stops.
        guard recording,
              let writerClockTime = writerTime(for: composedSample),
              startWriterIfNeeded(at: writerClockTime),
              let writerVideoInput,
              writerVideoInput.isReadyForMoreMediaData,
              let timedSample = retimed(composedSample) else { return }
        appendVideo(timedSample, to: writerVideoInput)
    }

    private func makeCanvasBuffer(from sampleBuffer: CMSampleBuffer, pool: CVPixelBufferPool? = nil) -> CMSampleBuffer? {
        guard let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        canvasLock.lock()
        let selectedCanvas = canvas
        let selectedZoom = softwareZoom
        canvasLock.unlock()

        var destination: CVPixelBuffer?
        guard let pool = pool ?? pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
              let destination else { return nil }

        let outputImage = FrameCompositor.aspectFill(
            touchUp.apply(to: CIImage(cvPixelBuffer: sourceBuffer)),
            width: selectedCanvas.width,
            height: selectedCanvas.height,
            zoom: selectedZoom
        )
        VideoEncoding.render(outputImage, to: destination, using: ciContext)

        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        )
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                            imageBuffer: destination,
                                                            formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription else { return nil }
        var outputSampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                       imageBuffer: destination,
                                                       formatDescription: formatDescription,
                                                       sampleTiming: &timing,
                                                       sampleBufferOut: &outputSampleBuffer) == noErr else { return nil }
        return outputSampleBuffer
    }

    /// Camera mode with touch-up on: the frame is composed once, shown as the
    /// preview and, while recording, written — the same pixels both ways.
    private func composedCameraPreview(from sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        canvasLock.lock()
        let pool = screenPixelBufferPool
        canvasLock.unlock()
        guard let composed = makeCanvasBuffer(from: sampleBuffer, pool: pool) else { return nil }
        CMSetAttachment(
            composed,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate
        )
        DispatchQueue.main.async { [weak self] in
            self?.onScreenPreviewFrame?(composed)
        }
        return composed
    }

    private func makeSampleBuffer(
        pixelBuffer: CVPixelBuffer,
        timingFrom sourceSampleBuffer: CMSampleBuffer
    ) -> CMSampleBuffer? {
        let sourceDuration = CMSampleBufferGetDuration(sourceSampleBuffer)
        var timing = CMSampleTimingInfo(
            duration: sourceDuration.isValid ? sourceDuration : CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sourceSampleBuffer),
            decodeTimeStamp: .invalid
        )
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }

    private func renderEmptyCanvasPreview(timingFrom sampleBuffer: CMSampleBuffer) {
        canvasLock.lock()
        let selectedCanvas = canvas
        let selectedZoom = softwareZoom
        let selectedPosition = pictureInPicturePosition
        let selectedCameraFrame = cameraFrameStyle
        let selectedCameraOrigin = cameraOrigin
        let selectedCameraScale = cameraOverlayScale
        let selectedBackdrop = canvasBackdrop
        let selectedMirrorInCompositor = mirrorInCompositor
        let pool = screenPixelBufferPool
        canvasLock.unlock()

        guard let pool, latestCameraBuffer != nil else { return }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
              let destination else { return }

        let canvasRect = CGRect(
            x: 0,
            y: 0,
            width: selectedCanvas.width,
            height: selectedCanvas.height
        )
        let emptyCanvas = CIImage(color: selectedBackdrop).cropped(to: canvasRect)
        let cameraLayer = composedCameraLayer(
            style: selectedCameraFrame,
            mirrorInCompositor: selectedMirrorInCompositor
        )

        let composed = FrameCompositor.screenWithCamera(
            screen: emptyCanvas,
            camera: cameraLayer?.image,
            width: selectedCanvas.width,
            height: selectedCanvas.height,
            cameraZoom: selectedZoom,
            position: selectedPosition,
            screenLayout: .fill,
            cameraFrame: selectedCameraFrame,
            cameraOrigin: selectedCameraOrigin,
            cameraScale: selectedCameraScale,
            personBox: cameraLayer?.personBox
        )
        VideoEncoding.render(composed, to: destination, using: ciContext)

        guard let previewSample = makeSampleBuffer(
            pixelBuffer: destination,
            timingFrom: sampleBuffer
        ) else { return }
        CMSetAttachment(
            previewSample,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate
        )
        DispatchQueue.main.async { [weak self] in
            self?.onScreenPreviewFrame?(previewSample)
        }

        // The canvas is recorded, not just previewed. Without this the video
        // track simply stops whenever there is no screen source — when one was
        // never picked, when sharing is stopped mid-take, or when a captured
        // window closes — leaving a file whose audio runs on over a frozen
        // picture. Writing the same frames the user is watching means the
        // absence of a screen source is a composition, not a failure.
        guard recording,
              let writerClockTime = writerTime(for: previewSample),
              startWriterIfNeeded(at: writerClockTime),
              let writerVideoInput,
              writerVideoInput.isReadyForMoreMediaData,
              let timedSample = retimed(previewSample) else { return }
        appendVideo(timedSample, to: writerVideoInput)
    }

    /// The camera layer as it should be composited, and where the person sits
    /// inside it. Both come back flipped together when the capture connection
    /// could not mirror for us, so nothing downstream has to know which of the
    /// two paths did the flip.
    private func composedCameraLayer(
        style: CameraFrameStyle,
        mirrorInCompositor: Bool
    ) -> (image: CIImage, personBox: CGRect?)? {
        guard let buffer = latestCameraBuffer else { return nil }
        // Before the cutout and the compositor's flip, so the face box from
        // the raw frame lines up and the mask's alpha is never touched.
        var image = touchUp.apply(to: CIImage(cvPixelBuffer: buffer))
        if style.needsPersonMask {
            // Without a mask yet there is nothing to cut out, so the overlay is
            // skipped for that frame rather than showing an uncut rectangle.
            guard let mask = currentPersonMask() else { return nil }
            image = FrameCompositor.personCutout(camera: image, mask: mask)
        }

        var personBox = currentPersonBox()
        if mirrorInCompositor {
            image = FrameCompositor.mirroredHorizontally(image)
            personBox = personBox.map(FrameCompositor.mirroredHorizontally)
        }
        return (image, personBox)
    }

    private func currentPersonMask() -> CIImage? {
        maskLock.lock()
        defer { maskLock.unlock() }
        return latestPersonMask
    }

    private func currentPersonBox() -> CGRect? {
        maskLock.lock()
        defer { maskLock.unlock() }
        return personTracker.box
    }

    /// Segmentation runs on its own queue so a slow mask never stalls capture or
    /// compositing; a frame in flight means this one is skipped, not queued.
    private func requestPersonMask(for buffer: CVPixelBuffer) {
        maskLock.lock()
        let busy = segmentationInFlight
        if !busy { segmentationInFlight = true }
        maskLock.unlock()
        guard !busy else { return }

        segmentationQueue.async { [weak self] in
            guard let self else { return }
            var mask: CIImage?
            var personBox: CGRect?
            var failure: Error?
            do {
                let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
                try handler.perform([self.segmentationRequest])
                if let result = self.segmentationRequest.results?.first {
                    mask = CIImage(cvPixelBuffer: result.pixelBuffer)
                    // Scanning the mask here costs a pass over ~200 KB on a
                    // queue that is already off the capture and compositing
                    // paths; the alternative is a second Vision request.
                    personBox = FrameCompositor.personBox(in: result.pixelBuffer)
                }
            } catch {
                failure = error
            }

            self.maskLock.lock()
            if failure == nil {
                self.latestPersonMask = mask
                self.personTracker.update(with: personBox)
            }
            self.segmentationInFlight = false
            let shouldReport = failure != nil && !self.didReportSegmentationFailure
            if shouldReport { self.didReportSegmentationFailure = true }
            self.maskLock.unlock()

            if let failure, shouldReport {
                DispatchQueue.main.async { self.onPersonSegmentationFailure?(failure) }
            }
        }
    }

    private static func makePixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        return pool
    }
}

private enum RecorderError: LocalizedError {
    case unsupportedRecordingFormat(String)
    case cannotAddVideoInput
    case cannotAddAudioInput
    case cannotAddWriterInput
    case cannotAddAudioWriterInput
    case microphoneUnavailable
    case cameraFrameUnavailable
    case writerFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedRecordingFormat(let format): "\(format) recording is unavailable on this Mac. Choose another format."
        case .cannotAddVideoInput: "Cannot add the selected camera to the capture session."
        case .cannotAddAudioInput: "Cannot add the selected microphone to the capture session."
        case .cannotAddWriterInput: "Cannot add the writer input."
        case .cannotAddAudioWriterInput: "Cannot add the audio track to the movie writer."
        case .microphoneUnavailable: "Microphone permission and a selected microphone are required before recording."
        case .cameraFrameUnavailable: "Wait for the camera preview before recording."
        case .writerFailed: "The movie writer failed."
        }
    }
}

private enum DragTarget {
    case camera
    case screen
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let previewView = PreviewView(frame: .zero)
    private let captureOptionsButton = NSButton(title: "", target: nil, action: nil)
    private let modeControl = NSSegmentedControl(
        labels: ["Camera", "Screen + Camera"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let chooseScreenButton = NSButton(title: "Choose Screen or Window…", target: nil, action: nil)
    private let screenLayoutControl = NSSegmentedControl(
        labels: ScreenLayoutMode.allCases.map(\.label),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let screenAlignmentControl = NSSegmentedControl(
        labels: ScreenVerticalAlignment.allCases.map(\.label),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let pipPositionControl = NSSegmentedControl(
        labels: ["↖", "↗", "↙", "↘"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let cameraFrameControl = NSSegmentedControl(
        images: CameraFrameStyle.allCases.map { style in
            NSImage(systemSymbolName: style.symbolName, accessibilityDescription: style.label)
                ?? NSImage(systemSymbolName: "person.crop.rectangle", accessibilityDescription: style.label)
                ?? NSImage(size: NSSize(width: 14, height: 14))
        },
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let zoomSlider = NSSlider(value: 1, minValue: 1, maxValue: 3, target: nil, action: nil)
    private let zoomValueLabel = NSTextField(labelWithString: "1.0×")
    private let recenterButton = NSButton(title: "", target: nil, action: nil)
    private let mirrorButton = NSButton(title: "", target: nil, action: nil)
    private let videoEffectsButton = NSButton(title: "Video Effects…", target: nil, action: nil)
    // Layout fixtures render the defaults and never write the user's look.
    private lazy var touchUpControl = TouchUpControl(
        settings: isLayoutReport ? .defaults : .stored(),
        persists: !isLayoutReport
    )
    private var cameraCaptureState: CameraCaptureState?
    private var qualityCheckRunning = false
    private let cameraSizeSlider = NSSlider(
        value: 1,
        minValue: Double(CameraOverlayScale.minimum),
        maxValue: Double(CameraOverlayScale.framedMaximum),
        target: nil,
        action: nil
    )
    private let recordButton = PrimaryRecordButton(frame: .zero)
    private let pauseButton = NSButton(title: "", target: nil, action: nil)
    private let audioMeter = AudioLevelMeter(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "Starting…")
    private let outputSizeLabel = NSTextField(labelWithString: "1920 × 1080")
    private let recordingFormatControl = NSSegmentedControl(
        labels: VideoRecordingFormat.allCases.map(\.label),
        trackingMode: .selectOne, target: nil, action: nil
    )
    private let recordingFormatDetail = NSTextField(labelWithString: "")
    private var devices: [AVCaptureDevice] = []
    private var audioDevices: [AVCaptureDevice] = []
    private var recorder: Recorder!
    private var screenCaptureController: ScreenCaptureController!
    private var currentCaptureMode: CaptureMode = .cameraOnly
    private var cameraSessionReady = false
    private var screenSourceReady = false
    private var configurationGeneration = 0
    private var recordingTimer: Timer?
    private var recordingStartDate: Date?
    /// Wall-clock bookkeeping for the on-screen timer, kept separate from the
    /// writer's sample clock: the label must count recorded time only, so a
    /// four-minute take with a one-minute pause reads 03:00, matching the file.
    private var pausedAccumulated: TimeInterval = 0
    private var pauseBeganAt: Date?
    private var recordingFileName = ""
    // Layout fixtures neither read nor change the saved folder choice.
    private lazy var recordingsFolder = RecordingsFolder(readsStoredFolder: !isLayoutReport)
    private let recordingCard = RecordingCardView(frame: .zero)
    /// The folder the current take is being written into. Held so a chosen
    /// folder's access outlives a mid-take change of folder.
    private var activeTakeFolder: RecordingsFolder.Access?
    /// The finished take the card offers, with the folder access its rename
    /// and trash actions still need.
    private var presentedRecording: (url: URL, folder: RecordingsFolder.Access)?
    /// Covers the countdown, where the recorder is not yet recording: the
    /// global hotkey bypasses the disabled Record button and would otherwise
    /// start a second take on top of the first.
    private var takeStarting = false
    private let systemAudioTap = SystemAudioTap()
    private var statusItem: NSStatusItem?
    private var hotKeys: [GlobalHotKey] = []
    /// The pause control only exists during a take. A hidden view still holds
    /// its constraints, so both its width and its spacing collapse to nothing —
    /// otherwise the meter would sit marooned 118pt from the Record button.
    private lazy var pauseButtonWidth = pauseButton.widthAnchor.constraint(equalToConstant: 0)
    private lazy var pauseButtonTrailing = pauseButton.trailingAnchor.constraint(
        equalTo: recordButton.leadingAnchor,
        constant: 0
    )
    private var permissionOnboarding: PermissionOnboardingController?
    private var mainInterfaceBuilt = false
    private var selectedCameraID: String?
    private var selectedMicrophoneID: String?
    /// The user chose to record without a microphone — a deliberate state,
    /// not a missing device. Recording stays allowed; the meter dims; a file
    /// without speech saves as a success instead of a warning.
    private var microphoneDisabled = false
    private var ratioButtons: [CanvasPresetButton] = []
    private var resolutionButtons: [CanvasPresetButton] = []
    private var previewAspectConstraint: NSLayoutConstraint?
    private var sourceGridRow: NSGridRow?
    private var screenGridRow: NSGridRow?
    private var overlayGridRow: NSGridRow?
    private let canvasBackdropWell = NSColorWell(frame: .zero)
    private var stageBackdropButtons: [NSButton] = []
    private weak var stageBackdropDots: NSStackView?
    private var selectedStageBackdropIndex = 0
    private weak var previewStageView: SurfaceView?
    private var cropGroup: NSStackView?
    private var pipGroup: NSStackView?
    private var cameraSizeGroup: NSStackView?
    private var cameraFrameGroup: NSStackView?
    private var cameraZoomGroup: NSStackView?
    private var cameraFlipGroup: NSStackView?
    private var cameraMirrored = false
    private let stopScreenButton = NSButton(title: "Stop Sharing", target: nil, action: nil)
    private let systemAudioCheckbox = NSButton(
        checkboxWithTitle: "System Audio",
        target: nil,
        action: nil
    )
    private let prompterButton = NSButton(title: "", target: nil, action: nil)
    private let countdownLabel = NSTextField(labelWithString: "")
    private let pausedBadge = PausedBadge()
    private var pauseHotKeyRegistered = true
    private var recordingMenu: NSMenu?
    private var spacePauseMonitor: Any?
    // Layout fixtures must neither read nor overwrite the user's saved script.
    private let teleprompter = TeleprompterController(
        persistsScript: CommandLine.arguments.dropFirst().first != "--layout-report"
    )
    private var cameraOrigin: CGPoint?
    private var cameraOverlayScale: CGFloat = 1
    private var screenCropOffset: CGPoint = .zero
    private let updateChecker = UpdateChecker()
    private var activeDrag: DragTarget?
    private var dragStartPoint: CGPoint = .zero
    private var dragStartCameraOrigin: CGPoint = .zero
    private var dragStartScreenCropOffset: CGPoint = .zero
    private var selectedRatioIndex = CanvasOptions.defaultRatioIndex
    private let isLayoutReport = CommandLine.arguments.dropFirst().first == "--layout-report"
    private var selectedResolutionIndex = CanvasOptions.defaultResolutionIndex
    private var selectedRecordingFormat = VideoRecordingFormat.stored(
        UserDefaults.standard.string(forKey: "recording.videoFormat")
    )
    private var appliedCanvas = CanvasOptions.defaultPreset

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read the bundle resource directly so macOS's icon cache cannot leave
        // the Dock or window header displaying a previous release's artwork.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        if !isLayoutReport, activateExistingInstance() { return }
        buildMainMenu()
        // Compiling the touch-up kernels takes about half a second. Do it now,
        // off the main thread, rather than on the first frame that needs them.
        DispatchQueue.global(qos: .userInitiated).async {
            let available = TouchUp.isAvailable
            Task { @MainActor [weak self] in self?.touchUpControl.isAvailable = available }
        }
        recorder = Recorder(previewLayer: previewView.previewLayer)
        configureScreenCapture()
        if isLayoutReport {
            enterMainInterface()
            return
        }
        showInitialInterface()
        installGlobalHotKeys()
        installSpacePause()
        updateChecker.checkAutomatically()
    }

    /// Two bundles at different paths share one bundle identifier, so macOS is
    /// happy to run both — and they would then share one UserDefaults domain and
    /// one script file, quietly overwriting each other's settings. Hand over to
    /// whichever copy got there first.
    private func activateExistingInstance() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0 != NSRunningApplication.current }
        guard let existing = others.first else { return false }

        // An instance that launched before the current binary was built is a
        // stale build. Deferring to it means every repackage silently reopens
        // the old version — replace it instead.
        let launchedAt = existing.launchDate ?? .distantPast
        let binaryBuiltAt = (Bundle.main.executablePath
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0) }?[.modificationDate]
            as? Date) ?? .distantPast
        if launchedAt < binaryBuiltAt {
            existing.terminate()
            return false
        }
        existing.activate()
        NSApp.terminate(nil)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        permissionOnboarding?.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        teleprompter.hide()
        // Nil when the single-instance guard terminates us before launch
        // finished — force-unwrapping here crashed every early handover.
        screenCaptureController?.stop()
    }

    private func configureScreenCapture() {
        let controller = ScreenCaptureController()
        screenCaptureController = controller
        let activeRecorder = recorder!
        let activePreview = previewView

        controller.onVideoSample = { [weak activeRecorder] sampleBuffer in
            activeRecorder?.handleScreenSampleBuffer(sampleBuffer)
        }
        systemAudioTap.onAudioSample = { [weak activeRecorder] sampleBuffer in
            activeRecorder?.handleAppAudioSampleBuffer(sampleBuffer)
        }
        systemAudioTap.onStartFailure = { [weak self] status in
            Task { @MainActor in self?.systemAudioFailedToStart(status: status) }
        }
        controller.onSelectionChanged = { [weak self] isReady, description in
            Task { @MainActor in
                guard let self else { return }
                self.screenSourceReady = isReady
                // Same wording as the system's "currently sharing" popover:
                // while sharing, picking more content *adds* windows.
                self.chooseScreenButton.title = isReady ? "Add Windows…" : "Choose Screen or Window…"
                self.stopScreenButton.isHidden = !isReady
                self.recorder.setScreenSourceActive(isReady)
                self.updateRecordAvailability()
                self.updateSystemAudioAvailability()
                // Picking or dropping a source mid-take is a shot change, not a
                // new session: the clock keeps the line and notes the change.
                if self.recorder.isRecording {
                    self.updateRecordingClock()
                    return
                }
                if self.currentCaptureMode == .screenAndCamera {
                    self.statusLabel.stringValue = isReady
                        ? "Screen source active · camera will appear as picture-in-picture"
                        : description
                }
            }
        }
        controller.onPickerDidSelect = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true)
                // Explicitly the main window: the teleprompter overlay is also
                // on screen and would happily take the key window instead.
                self.window?.makeKeyAndOrderFront(nil)
            }
        }
        controller.onError = { [weak self] error in
            Task { @MainActor in
                self?.statusLabel.stringValue = "Screen capture failed: \(error.localizedDescription)"
            }
        }
        activeRecorder.onScreenPreviewFrame = { [weak activePreview] sampleBuffer in
            activePreview?.displayComposedFrame(sampleBuffer)
        }
        activeRecorder.onAudioLevel = { [weak self] decibels in
            MainActor.assumeIsolated { self?.audioMeter.report(decibels: decibels) }
        }
        // Follow voice hears the microphone the take records, through this
        // session — rehearsal included, since the preview keeps it running.
        let voiceFollow = teleprompter.voiceFollow
        activeRecorder.setMicrophoneSampleHandler { sampleBuffer in
            voiceFollow.appendMicrophone(sampleBuffer)
        }
        activeRecorder.onCaptureStateChange = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cameraCaptureState = state
                self.videoEffectsButton.title = state.effectsTitle
                if self.canConfigureOutput { self.applyCanvasOptions(announce: false) }
                self.updateCaptureQualityDescription()
            }
        }
        activeRecorder.onRecordingCanvasChange = { [weak self] canvas in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.appliedCanvas = canvas
                self.updatePreviewSize(for: canvas)
                self.updateCaptureQualityDescription()
            }
        }
        // A canvas change moves the camera onto a different format with no
        // other visible event, so the resolution on screen has to follow it or
        // it is only correct until the first ratio click.
        activeRecorder.onCameraFormatChange = { [weak self] format in
            MainActor.assumeIsolated {
                guard let self, let format else { return }
                self.statusLabel.stringValue = "Camera now \(format.width) × \(format.height) for this canvas"
            }
        }
        activeRecorder.onPersonSegmentationFailure = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.statusLabel.stringValue = "Cutout unavailable on this Mac: \(error.localizedDescription) · pick Rectangle or Circle"
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func showInitialInterface() {
        let videoAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        let audioAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if videoAuthorized && audioAuthorized {
            enterMainInterface()
            return
        }

        let onboarding = PermissionOnboardingController { [weak self] in
            self?.enterMainInterface()
        }
        permissionOnboarding = onboarding
        window = onboarding.window
        onboarding.show()
    }

    private func enterMainInterface() {
        guard !mainInterfaceBuilt else { return }
        mainInterfaceBuilt = true
        permissionOnboarding?.close()
        permissionOnboarding = nil
        buildRedesignedWindow()
        if !isLayoutReport {
            reloadDevices(preservingSelection: false)
            refreshAuthorizationAndConfigure(requestIfNeeded: false)
        }
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "OneAct")
        let aboutItem = appMenu.addItem(
            withTitle: "About OneAct",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        appMenu.addItem(.separator())
        let updateItem = appMenu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(
            withTitle: "Quit OneAct",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        let showFolderItem = fileMenu.addItem(
            withTitle: "Show Recordings Folder", action: #selector(showRecordingsFolder), keyEquivalent: ""
        )
        showFolderItem.target = self
        let chooseFolderItem = fileMenu.addItem(
            withTitle: "Choose Recordings Folder…", action: #selector(chooseRecordingsFolder), keyEquivalent: ""
        )
        chooseFolderItem.target = self
        fileMenuItem.submenu = fileMenu

        // AppKit routes Cmd-key equivalents through the main menu before the
        // responder chain, so a text view only gets paste if this menu exists.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(
            withTitle: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "Z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: Selector(("delete:")), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        // Where Mac users look for shortcuts. The global hot keys take ⌥⌘R
        // and ⌥⌘P before the menu sees them, so each fires once; if one could
        // not be registered, the menu still answers while OneAct is in front.
        // Titles and enabling come from validateMenuItem.
        let recordingMenuItem = NSMenuItem()
        mainMenu.addItem(recordingMenuItem)
        let recordingMenu = NSMenu(title: "Recording")
        let recordItem = recordingMenu.addItem(
            withTitle: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r"
        )
        recordItem.keyEquivalentModifierMask = [.option, .command]
        recordItem.target = self
        let pauseItem = recordingMenu.addItem(
            withTitle: "Pause Recording", action: #selector(togglePause), keyEquivalent: "p"
        )
        pauseItem.keyEquivalentModifierMask = [.option, .command]
        pauseItem.subtitle = "Or press Space while OneAct is in front"
        pauseItem.target = self
        recordingMenuItem.submenu = recordingMenu
        self.recordingMenu = recordingMenu

        let cameraMenuItem = NSMenuItem()
        mainMenu.addItem(cameraMenuItem)
        let cameraMenu = NSMenu(title: "Camera")
        let refreshItem = cameraMenu.addItem(
            withTitle: "Refresh Devices",
            action: #selector(refreshDevices),
            keyEquivalent: "r"
        )
        refreshItem.keyEquivalentModifierMask = [.command]
        refreshItem.target = self
        let effectsItem = cameraMenu.addItem(
            withTitle: "Video Effects…", action: #selector(showVideoEffects), keyEquivalent: ""
        )
        effectsItem.target = self
        cameraMenu.addItem(.separator())
        let qualityItem = cameraMenu.addItem(
            withTitle: "Capture Quality Check (8 seconds)", action: #selector(captureQualityCheck), keyEquivalent: ""
        )
        qualityItem.target = self
        cameraMenuItem.submenu = cameraMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = mainMenu
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updateChecker.checkManually()
    }

    @objc private func showVideoEffects() {
        guard !qualityCheckRunning, cameraSessionReady else { return }
        AVCaptureDevice.showSystemUserInterface(.videoEffects)
    }

    /// Explicit diagnostic action, using the already-running UI capture
    /// session so macOS's per-app video effects are represented faithfully.
    @objc private func captureQualityCheck() {
        guard !qualityCheckRunning, cameraSessionReady, canConfigureOutput, modeControl.selectedSegment == 0 else {
            statusLabel.stringValue = "Stop recording and switch to Camera before checking quality."
            return
        }
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OneAct/Diagnostics/\(UUID().uuidString)", isDirectory: true)
            let diagnostics = try CameraFrameDiagnostics(directory: directory)
            qualityCheckRunning = true
            recorder.setFrameDiagnostics(diagnostics)
            recordButton.isEnabled = false
            recorder.startRecording(to: directory.appendingPathComponent("recording.mov")) { [weak self] result in
                guard let self else { return }
                if case .failure(let error) = result {
                    self.qualityCheckRunning = false
                    self.recorder.setFrameDiagnostics(nil)
                    self.statusLabel.stringValue = "Quality check failed: \(error.localizedDescription)"
                    self.updateRecordAvailability()
                    return
                }
                self.updateConfigurationAvailability()
                self.recordButton.setRecordingAppearance(true)
                self.statusLabel.stringValue = "Checking camera quality · capturing 8 seconds locally…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    self.recorder.stopRecording { result in
                        self.qualityCheckRunning = false
                        self.recorder.setFrameDiagnostics(nil)
                        self.recordButton.setRecordingAppearance(false)
                        self.updateConfigurationAvailability()
                        self.updateRecordAvailability()
                        if case .failure(let error) = result {
                            self.statusLabel.stringValue = "Quality check failed: \(error.localizedDescription)"
                            return
                        }
                        diagnostics.finish { result in
                            DispatchQueue.main.async {
                                switch result {
                                case .success:
                                    self.statusLabel.stringValue = "Quality check saved: \(directory.path)"
                                case .failure(let error):
                                    self.statusLabel.stringValue = "Quality check failed: \(error.localizedDescription)"
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            statusLabel.stringValue = "Quality check failed: \(error.localizedDescription)"
        }
    }

    /// Stop and pause are the two things you need while looking at the app you
    /// are demonstrating, not at OneAct. Switching back to the main window to
    /// press a button costs the demoed app its focus — menus close, focus rings
    /// vanish — in the last seconds of the take, exactly where it shows.
    private func installGlobalHotKeys() {
        let optionCommand = UInt32(optionKey | cmdKey)
        let record = GlobalHotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: optionCommand) { [weak self] in
            self?.toggleRecording()
        }
        let pause = GlobalHotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: optionCommand) { [weak self] in
            self?.togglePause()
        }
        hotKeys = [record, pause].compactMap { $0 }
        // Another app holding a combination is no reason to fail. The
        // Recording menu still answers to it while OneAct is in front; only
        // "from any app" is no longer true, so the tooltips stop saying it.
        recordButton.shortcutIsGlobal = record != nil
        pauseHotKeyRegistered = pause != nil
        setPauseButtonTitle(paused: recorder?.isPaused ?? false)
    }

    /// Space toggles pause while OneAct's window (or the teleprompter riding on
    /// it) is in front; see `SpacePause` for why it is not global.
    private func installSpacePause() {
        spacePauseMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                switch self.spacePauseDecision(for: event, in: event.window) {
                case .pass:
                    return event
                case .swallow:
                    return nil
                case .toggle:
                    self.togglePause()
                    return nil
                }
            }
        }
    }

    private func spacePauseDecision(for event: NSEvent, in eventWindow: NSWindow?) -> SpacePause.Decision {
        let state = reportRecordingState ?? (recorder.isRecording, recorder.isPaused)
        let inOneAct = eventWindow.map { $0 === window || $0.parent === window } ?? false
        // An editable text view — the teleprompter script outside a take, a
        // rename field — is someone typing a space, not pausing.
        let typing = (eventWindow?.firstResponder as? NSTextView)?.isEditable == true
        return SpacePause.decide(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            isRepeat: event.isARepeat,
            takeRunning: state.recording && !qualityCheckRunning,
            inOneActWindow: inOneAct,
            typing: typing
        )
    }

    /// "⌥⌘R" for a menu item's key equivalent, the way menus show it.
    private static func shortcutText(_ item: NSMenuItem) -> String {
        let mask = item.keyEquivalentModifierMask
        var text = ""
        if mask.contains(.control) { text += "⌃" }
        if mask.contains(.option) { text += "⌥" }
        if mask.contains(.shift) || item.keyEquivalent != item.keyEquivalent.lowercased() { text += "⇧" }
        if mask.contains(.command) { text += "⌘" }
        return text + item.keyEquivalent.uppercased()
    }

    /// Layout report: the decisions Space would get mid-take, from synthetic
    /// key events, plus the pure rule's cases no live window can stage.
    private func spacePauseReport() -> String {
        func key(_ modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false, code: Int = kVK_Space) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: code == kVK_Space ? " " : "p",
                charactersIgnoringModifiers: code == kVK_Space ? " " : "p",
                isARepeat: repeated,
                keyCode: UInt16(code)
            )
        }
        var results: [(name: String, got: String, ok: Bool)] = []
        func check(_ name: String, _ event: NSEvent?, _ target: NSWindow?, expect: SpacePause.Decision) {
            guard let event else { return results.append((name, "no_event", false)) }
            let decision = spacePauseDecision(for: event, in: target)
            results.append((name, decision.rawValue, decision == expect))
        }
        func check(_ name: String, _ decision: SpacePause.Decision, expect: SpacePause.Decision) {
            results.append((name, decision.rawValue, decision == expect))
        }
        let taking = (reportRecordingState?.recording ?? false) && !qualityCheckRunning
        check("main", key(), window, expect: taking ? .toggle : .pass)
        check("held", key(repeated: true), window, expect: taking ? .swallow : .pass)
        check("command_space", key(.command), window, expect: .pass)
        check("other_key", key(code: kVK_ANSI_P), window, expect: .pass)
        check("other_app_window", key(), nil, expect: .pass)
        check("idle", SpacePause.decide(keyCode: UInt16(kVK_Space), modifiers: [], isRepeat: false,
                                        takeRunning: false, inOneActWindow: true, typing: false), expect: .pass)
        check("typing", SpacePause.decide(keyCode: UInt16(kVK_Space), modifiers: [], isRepeat: false,
                                          takeRunning: true, inOneActWindow: true, typing: true), expect: .pass)
        let ok = results.allSatisfy(\.ok)
        return results.map { "\($0.name)=\($0.got)" }.joined(separator: " ") + " ok=\(ok)"
    }

    /// The menu bar entry only exists while a take is running: a permanent icon
    /// would be one more thing in the menu bar for an app that is not a
    /// background utility.
    private func updateStatusItem() {
        guard recorder.isRecording else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }

        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        let paused = recorder.isPaused
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: paused ? "pause.circle.fill" : "record.circle.fill",
                accessibilityDescription: paused ? "Recording paused" : "Recording"
            )
            button.imagePosition = .imageLeading
            button.title = " \(recordedClockText)"
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.contentTintColor = paused ? .secondaryLabelColor : .systemRed
        }

        let menu = NSMenu()
        let pauseItem = menu.addItem(
            withTitle: paused ? "Resume Recording" : "Pause Recording",
            action: #selector(togglePause),
            keyEquivalent: "p"
        )
        pauseItem.keyEquivalentModifierMask = [.option, .command]
        pauseItem.target = self
        let stopItem = menu.addItem(
            withTitle: "Stop Recording",
            action: #selector(toggleRecording),
            keyEquivalent: "r"
        )
        stopItem.keyEquivalentModifierMask = [.option, .command]
        stopItem.target = self
        menu.addItem(.separator())
        let showItem = menu.addItem(
            withTitle: "Show OneAct",
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        showItem.target = self
        item.menu = menu
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildRedesignedWindow() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 780))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let appIcon = NSImageView()
        if Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil {
            appIcon.image = NSApp.applicationIconImage
        } else {
            appIcon.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "OneAct")
            appIcon.contentTintColor = .systemRed
        }
        appIcon.imageScaling = .scaleProportionallyUpOrDown

        let titleLabel = NSTextField(labelWithString: "OneAct")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.toolTip = "Camera and screen recording, composed your way"

        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let versionLabel = NSTextField(labelWithString: appVersion.map { "v\($0)" } ?? "dev")
        versionLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.alignment = .right

        let previewStage = SurfaceView(style: .previewStage)
        let controlDeck = SurfaceView(style: .controls)

        let rootViews: [NSView] = [
            appIcon, titleLabel, versionLabel, modeControl, prompterButton,
            previewStage, controlDeck, statusLabel, audioMeter, pauseButton, recordButton,
            captureOptionsButton
        ]
        for view in rootViews {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewStage.addSubview(previewView)
        previewStageView = previewStage
        previewStage.setBackdropColor(StageBackdropPreset.all[storedStageBackdropIndex()].color)
        selectedStageBackdropIndex = storedStageBackdropIndex()
        let stageDots = makeStageBackdropDots()
        stageBackdropDots = stageDots
        stageDots.translatesAutoresizingMaskIntoConstraints = false
        stageDots.alphaValue = 0
        previewStage.addSubview(stageDots)
        previewStage.onHoverChanged = { hovering in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                stageDots.animator().alphaValue = hovering ? 1 : 0
            }
        }
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 96, weight: .semibold)
        countdownLabel.textColor = .white
        countdownLabel.alignment = .center
        countdownLabel.isHidden = true
        previewStage.addSubview(countdownLabel)
        pausedBadge.translatesAutoresizingMaskIntoConstraints = false
        pausedBadge.isHidden = true
        previewStage.addSubview(pausedBadge)
        // Above the preview and on the stage's bottom edge, clear of the
        // teleprompter, which hugs the top.
        recordingCard.translatesAutoresizingMaskIntoConstraints = false
        recordingCard.isHidden = true
        previewStage.addSubview(recordingCard)
        wireRecordingCard()
        previewView.onDragBegan = { [weak self] point in self?.beginPreviewDrag(at: point) }
        previewView.onDragMoved = { [weak self] point in self?.updatePreviewDrag(to: point) }
        previewView.onDragEnded = { [weak self] in self?.activeDrag = nil }

        // The mode switch sits above the preview: it decides what the stage shows.
        modeControl.target = self
        modeControl.action = #selector(captureModeChanged)
        modeControl.selectedSegment = 0
        modeControl.setWidth(112, forSegment: 0)
        modeControl.setWidth(156, forSegment: 1)
        modeControl.toolTip = "Choose camera-only or screen with camera picture-in-picture"

        chooseScreenButton.target = self
        chooseScreenButton.action = #selector(chooseScreenSource)
        chooseScreenButton.bezelStyle = .rounded
        stopScreenButton.target = self
        stopScreenButton.action = #selector(stopScreenSharing)
        systemAudioCheckbox.target = self
        systemAudioCheckbox.action = #selector(systemAudioToggled)
        systemAudioCheckbox.controlSize = .small
        systemAudioCheckbox.font = .systemFont(ofSize: 11)
        systemAudioCheckbox.state = .off
        stopScreenButton.bezelStyle = .rounded
        stopScreenButton.image = NSImage(
            systemSymbolName: "stop.circle",
            accessibilityDescription: "Stop sharing"
        )
        stopScreenButton.imagePosition = .imageLeading
        stopScreenButton.toolTip = "Stop capturing the selected screen or window"
        stopScreenButton.isHidden = true

        screenLayoutControl.target = self
        screenLayoutControl.action = #selector(screenLayoutChanged)
        screenLayoutControl.selectedSegment = ScreenLayoutMode.blur.rawValue
        screenLayoutControl.setLabel("Blur", forSegment: ScreenLayoutMode.blur.rawValue)
        screenLayoutControl.setToolTip(ScreenLayoutMode.blur.label, forSegment: ScreenLayoutMode.blur.rawValue)
        for index in 0..<screenLayoutControl.segmentCount {
            screenLayoutControl.setWidth(66, forSegment: index)
        }
        screenAlignmentControl.target = self
        screenAlignmentControl.action = #selector(screenAlignmentChanged)
        screenAlignmentControl.selectedSegment = ScreenVerticalAlignment.center.rawValue
        for index in 0..<screenAlignmentControl.segmentCount {
            screenAlignmentControl.setWidth(60, forSegment: index)
        }
        pipPositionControl.target = self
        pipPositionControl.action = #selector(pictureInPicturePositionControlChanged)
        pipPositionControl.selectedSegment = PictureInPicturePosition.bottomRight.rawValue
        for index in 0..<pipPositionControl.segmentCount {
            pipPositionControl.setWidth(34, forSegment: index)
            pipPositionControl.setToolTip(PictureInPicturePosition.allCases[index].label, forSegment: index)
        }
        cameraFrameControl.target = self
        cameraFrameControl.action = #selector(cameraFrameStyleChanged)
        cameraFrameControl.selectedSegment = CameraFrameStyle.rectangle.rawValue
        for index in 0..<cameraFrameControl.segmentCount {
            cameraFrameControl.setWidth(34, forSegment: index)
            cameraFrameControl.setToolTip(CameraFrameStyle.allCases[index].detail, forSegment: index)
        }

        pauseButton.bezelStyle = .rounded
        pauseButton.controlSize = .large
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.isHidden = true
        setPauseButtonTitle(paused: false)

        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        recordButton.setRecordingAppearance(false)
        recordButton.isEnabled = false
        recordButton.keyEquivalent = "\r"
        captureOptionsButton.target = self
        captureOptionsButton.action = #selector(showCaptureOptions(_:))
        captureOptionsButton.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: "Camera and microphone options"
        )
        captureOptionsButton.title = ""
        captureOptionsButton.bezelStyle = .rounded
        captureOptionsButton.toolTip = "Camera, microphone, and device options"
        prompterButton.target = self
        prompterButton.action = #selector(toggleTeleprompter)
        prompterButton.image = NSImage(
            systemSymbolName: "text.alignleft",
            accessibilityDescription: "Teleprompter"
        )
        prompterButton.bezelStyle = .rounded
        prompterButton.setButtonType(.pushOnPushOff)
        prompterButton.toolTip = "Teleprompter · a floating script panel that stays out of recordings"
        teleprompter.onVisibilityChanged = { [weak self] visible in
            self?.prompterButton.state = visible ? .on : .off
        }
        teleprompter.onStatusMessage = { [weak self] message in
            self?.statusLabel.stringValue = message
        }
        teleprompter.voiceFollow.microphoneProblem = { [weak self] in
            self?.followVoiceMicrophoneProblem
        }

        zoomSlider.target = self
        zoomSlider.action = #selector(zoomChanged)
        zoomSlider.minValue = Double(SoftwareZoom.minimum)
        zoomSlider.maxValue = Double(SoftwareZoom.maximum)
        zoomSlider.doubleValue = 1
        zoomSlider.isContinuous = true
        zoomSlider.numberOfTickMarks = 0
        zoomSlider.toolTip = "Software zoom applied to preview and recording · centre crop up to 3×"
        recenterButton.target = self
        recenterButton.action = #selector(recenterZoom)
        recenterButton.bezelStyle = .rounded
        recenterButton.image = NSImage(
            systemSymbolName: "arrow.counterclockwise",
            accessibilityDescription: "Reset zoom"
        )
        recenterButton.toolTip = "Back to 1.0×"
        videoEffectsButton.target = self
        videoEffectsButton.action = #selector(showVideoEffects)
        videoEffectsButton.bezelStyle = .rounded
        videoEffectsButton.font = .systemFont(ofSize: 11)
        videoEffectsButton.toolTip = "macOS applies these effects before OneAct receives the camera frame. Portrait softens the background and edges; click to adjust video effects."
        mirrorButton.target = self
        mirrorButton.action = #selector(cameraMirrorChanged)
        mirrorButton.bezelStyle = .rounded
        mirrorButton.setButtonType(.pushOnPushOff)
        mirrorButton.image = NSImage(
            systemSymbolName: "arrow.left.and.right.righttriangle.left.righttriangle.right",
            accessibilityDescription: "Flip the camera left to right"
        ) ?? NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Flip the camera left to right")
        mirrorButton.toolTip = "Flip the camera left to right · applies to the preview and the recording"
        cameraSizeSlider.target = self
        cameraSizeSlider.action = #selector(cameraSizeChanged)
        cameraSizeSlider.isContinuous = true
        cameraSizeSlider.numberOfTickMarks = 0
        cameraSizeSlider.toolTip = "Size of the camera overlay on the canvas"

        zoomValueLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        zoomValueLabel.alignment = .left
        zoomValueLabel.textColor = .secondaryLabelColor
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.alignment = .left
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        outputSizeLabel.textColor = .tertiaryLabelColor
        outputSizeLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        outputSizeLabel.alignment = .left
        recordingFormatControl.selectedSegment = VideoRecordingFormat.allCases.firstIndex(of: selectedRecordingFormat) ?? 0
        recordingFormatControl.target = self
        recordingFormatControl.action = #selector(recordingFormatChanged)
        recordingFormatControl.toolTip = "Choose the recording format before starting a take."
        recordingFormatDetail.font = .systemFont(ofSize: 11)
        recordingFormatDetail.textColor = .secondaryLabelColor
        recordingFormatDetail.stringValue = selectedRecordingFormat.detail
        recorder.setRecordingFormat(selectedRecordingFormat)

        ratioButtons = CanvasOptions.ratios.enumerated().map { index, ratio in
            let button = CanvasPresetButton(presetIndex: index, title: ratio.label)
            button.target = self
            button.action = #selector(canvasRatioSelected(_:))
            button.toolTip = "\(ratio.label) · \(ratio.name)"
            button.setSelected(index == selectedRatioIndex)
            return button
        }
        resolutionButtons = CanvasOptions.resolutions.enumerated().map { index, resolution in
            let button = CanvasPresetButton(presetIndex: index, title: resolution.label)
            button.target = self
            button.action = #selector(canvasResolutionSelected(_:))
            button.toolTip = "\(resolution.detail) output quality"
            button.setSelected(index == selectedResolutionIndex)
            return button
        }

        let sourceRow = controlRow(
            [chooseScreenButton, stopScreenButton, systemAudioCheckbox],
            spacing: 8
        )
        sourceRow.setClippingResistancePriority(.defaultLow, for: .horizontal)
        // A full picker rather than a fixed palette: this colour is composited
        // into the recording, so people match it to their own branding.
        canvasBackdropWell.colorWellStyle = .expanded
        canvasBackdropWell.color = storedCanvasBackdropColor() ?? .black
        canvasBackdropWell.target = self
        canvasBackdropWell.action = #selector(canvasBackdropColorChanged)
        canvasBackdropWell.toolTip = "Canvas backdrop · fills Fit bars and the empty canvas, and is recorded"
        canvasBackdropWell.translatesAutoresizingMaskIntoConstraints = false
        canvasBackdropWell.widthAnchor.constraint(equalToConstant: 48).isActive = true
        canvasBackdropWell.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let backdropGroup = controlRow([miniCaption("BG"), canvasBackdropWell], spacing: 6)
        let alignmentGroup = controlRow([miniCaption("CROP"), screenAlignmentControl], spacing: 6)
        let screenRow = controlRow([screenLayoutControl, backdropGroup, alignmentGroup], spacing: 16)
        let positionGroup = controlRow([miniCaption("PIP"), pipPositionControl], spacing: 6)
        let frameGroup = controlRow([miniCaption("FRAME"), cameraFrameControl], spacing: 6)
        let sizeGroup = controlRow([miniCaption("SIZE"), cameraSizeSlider], spacing: 6)
        let zoomGroup = controlRow([miniCaption("ZOOM"), zoomSlider, zoomValueLabel, recenterButton], spacing: 8)
        let flipGroup = controlRow([miniCaption("FLIP"), mirrorButton], spacing: 6)
        // Overlay styling (frame, size, corner) is one concern, camera capture
        // (zoom, flip) another: two short rows instead of one long one, with the
        // camera row next to CANVAS where the other output-framing settings live.
        let overlayRow = controlRow([frameGroup, sizeGroup, positionGroup], spacing: 16)
        let cameraRow = controlRow([zoomGroup, flipGroup, touchUpControl.button, videoEffectsButton], spacing: 16)
        let canvasRow = controlRow([
            controlRow(ratioButtons, spacing: 5),
            verticalDivider(),
            controlRow(resolutionButtons, spacing: 5),
            outputSizeLabel
        ], spacing: 12)

        cropGroup = alignmentGroup
        pipGroup = positionGroup
        cameraSizeGroup = sizeGroup
        cameraFrameGroup = frameGroup
        cameraZoomGroup = zoomGroup
        cameraFlipGroup = flipGroup

        let grid = NSGridView(views: [
            [gutterLabel("SOURCE"), sourceRow],
            [gutterLabel("SCREEN"), screenRow],
            [gutterLabel("OVERLAY"), overlayRow],
            [gutterLabel("CAMERA"), cameraRow],
            [gutterLabel("CANVAS"), canvasRow],
            [gutterLabel("FORMAT"), controlRow([recordingFormatControl, recordingFormatDetail], spacing: 12)]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 58
        grid.column(at: 1).xPlacement = .leading
        for index in 0..<grid.numberOfRows {
            grid.row(at: index).yPlacement = .center
        }
        sourceGridRow = grid.row(at: 0)
        screenGridRow = grid.row(at: 1)
        overlayGridRow = grid.row(at: 2)
        controlDeck.addSubview(grid)

        NSLayoutConstraint.activate([
            appIcon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            appIcon.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            appIcon.widthAnchor.constraint(equalToConstant: 20),
            appIcon.heightAnchor.constraint(equalToConstant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: appIcon.trailingAnchor, constant: 9),
            titleLabel.centerYAnchor.constraint(equalTo: appIcon.centerYAnchor),
            modeControl.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            modeControl.centerYAnchor.constraint(equalTo: appIcon.centerYAnchor),
            modeControl.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
            versionLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            versionLabel.centerYAnchor.constraint(equalTo: appIcon.centerYAnchor),
            prompterButton.trailingAnchor.constraint(equalTo: versionLabel.leadingAnchor, constant: -12),
            prompterButton.centerYAnchor.constraint(equalTo: appIcon.centerYAnchor),
            prompterButton.widthAnchor.constraint(equalToConstant: 34),
            prompterButton.leadingAnchor.constraint(greaterThanOrEqualTo: modeControl.trailingAnchor, constant: 16),

            previewStage.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 14),
            previewStage.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            previewStage.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            previewStage.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            previewStage.bottomAnchor.constraint(equalTo: controlDeck.topAnchor, constant: -12),

            stageDots.trailingAnchor.constraint(equalTo: previewStage.trailingAnchor, constant: -9),
            stageDots.centerYAnchor.constraint(equalTo: previewStage.centerYAnchor),
            countdownLabel.centerXAnchor.constraint(equalTo: previewStage.centerXAnchor),
            countdownLabel.centerYAnchor.constraint(equalTo: previewStage.centerYAnchor),
            pausedBadge.centerXAnchor.constraint(equalTo: previewStage.centerXAnchor),
            pausedBadge.centerYAnchor.constraint(equalTo: previewStage.centerYAnchor),
            pausedBadge.widthAnchor.constraint(lessThanOrEqualTo: previewStage.widthAnchor, constant: -32),
            recordingCard.centerXAnchor.constraint(equalTo: previewStage.centerXAnchor),
            recordingCard.bottomAnchor.constraint(equalTo: previewStage.bottomAnchor, constant: -16),
            recordingCard.widthAnchor.constraint(lessThanOrEqualTo: previewStage.widthAnchor, constant: -32),
            previewView.centerXAnchor.constraint(equalTo: previewStage.centerXAnchor),
            previewView.centerYAnchor.constraint(equalTo: previewStage.centerYAnchor),
            previewView.widthAnchor.constraint(lessThanOrEqualTo: previewStage.widthAnchor, constant: -36),
            previewView.heightAnchor.constraint(lessThanOrEqualTo: previewStage.heightAnchor, constant: -32),

            controlDeck.leadingAnchor.constraint(equalTo: previewStage.leadingAnchor),
            controlDeck.trailingAnchor.constraint(equalTo: previewStage.trailingAnchor),
            controlDeck.bottomAnchor.constraint(equalTo: recordButton.topAnchor, constant: -14),
            grid.topAnchor.constraint(equalTo: controlDeck.topAnchor, constant: 16),
            grid.bottomAnchor.constraint(equalTo: controlDeck.bottomAnchor, constant: -16),
            grid.leadingAnchor.constraint(equalTo: controlDeck.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: controlDeck.trailingAnchor, constant: -20),

            zoomSlider.widthAnchor.constraint(equalToConstant: 110),
            zoomValueLabel.widthAnchor.constraint(equalToConstant: 40),
            recenterButton.widthAnchor.constraint(equalToConstant: 28),
            cameraSizeSlider.widthAnchor.constraint(equalToConstant: 100),

            captureOptionsButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            captureOptionsButton.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor),
            captureOptionsButton.widthAnchor.constraint(equalToConstant: 38),
            captureOptionsButton.heightAnchor.constraint(equalToConstant: 38),
            recordButton.trailingAnchor.constraint(equalTo: captureOptionsButton.leadingAnchor, constant: -8),
            recordButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            recordButton.widthAnchor.constraint(equalToConstant: 168),
            recordButton.heightAnchor.constraint(equalToConstant: 38),
            pauseButtonTrailing,
            pauseButtonWidth,
            pauseButton.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor),
            pauseButton.heightAnchor.constraint(equalToConstant: 38),
            audioMeter.trailingAnchor.constraint(equalTo: pauseButton.leadingAnchor, constant: -14),
            audioMeter.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            statusLabel.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: audioMeter.leadingAnchor, constant: -16)
        ])

        for button in ratioButtons {
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        for button in resolutionButtons {
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            button.widthAnchor.constraint(equalToConstant: 52).isActive = true
        }

        let preferredPreviewWidth = previewView.widthAnchor.constraint(
            equalTo: previewStage.widthAnchor, constant: -36
        )
        let preferredPreviewHeight = previewView.heightAnchor.constraint(
            equalTo: previewStage.heightAnchor, constant: -32
        )
        for constraint in [preferredPreviewWidth, preferredPreviewHeight] {
            constraint.priority = .defaultLow
            constraint.isActive = true
        }

        recorder.setScreenLayoutMode(.blur)
        recorder.setScreenVerticalAlignment(.center)
        recorder.setCameraFrameStyle(.rectangle)
        touchUpControl.onChange = { [weak self] settings in self?.applyTouchUp(settings, announce: true) }
        applyTouchUp(touchUpControl.settings, announce: false)
        applyCanvasBackdrop(canvasBackdropWell.color, announce: false)
        window = NSWindow(
            contentRect: content.bounds,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OneAct"
        window.contentView = content
        window.center()
        window.setContentSize(content.bounds.size)
        window.minSize = NSSize(width: 920, height: 640)
        window.isMovableByWindowBackground = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        teleprompter.attach(stage: previewStage, host: window)
        applyCanvasOptions(announce: false)
        applySoftwareZoom(1, announce: false)
        updateModeSpecificControls()
    }

    private func controlRow(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = spacing
        return stack
    }

    private func gutterLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.alignment = .right
        return label
    }

    private func miniCaption(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func verticalDivider() -> NSView {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 18)
        ])
        return divider
    }

    /// Camera and microphone live in the record button's menu, the way QuickTime
    /// keeps its capture options, so the window itself stays free of device rows.
    @objc private func showCaptureOptions(_ sender: NSButton) {
        makeCaptureOptionsMenu().popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.bounds.height + 4),
            in: sender
        )
    }

    func makeCaptureOptionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let locked = !canConfigureOutput

        menu.addItem(NSMenuItem.sectionHeader(title: "Camera"))
        if devices.isEmpty {
            menu.addItem(disabledMenuItem("No cameras found"))
        } else {
            for (index, device) in devices.enumerated() {
                let suffix = device.isContinuityCamera ? " · Continuity Camera" : ""
                let item = NSMenuItem(
                    title: device.localizedName + suffix,
                    action: #selector(cameraSelectedFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = index
                item.state = device.uniqueID == selectedCameraID ? .on : .off
                item.isEnabled = !locked
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.sectionHeader(title: "Microphone"))
        let noneItem = NSMenuItem(
            title: "None (no microphone)",
            action: #selector(microphoneNoneSelected),
            keyEquivalent: ""
        )
        noneItem.target = self
        noneItem.state = microphoneDisabled ? .on : .off
        noneItem.isEnabled = !locked
        menu.addItem(noneItem)
        if audioDevices.isEmpty {
            menu.addItem(disabledMenuItem("No microphones found"))
        } else {
            for (index, device) in audioDevices.enumerated() {
                let item = NSMenuItem(
                    title: device.localizedName,
                    action: #selector(microphoneSelectedFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = index
                item.state = !microphoneDisabled && device.uniqueID == selectedMicrophoneID ? .on : .off
                item.isEnabled = !locked
                menu.addItem(item)
            }
        }

        // QuickTime keeps "Save to" in this same menu: where the take goes is
        // decided with the devices, before Record, never in a panel after it.
        menu.addItem(NSMenuItem.sectionHeader(title: "Save To"))
        let defaultFolderItem = NSMenuItem(
            title: RecordingsFolder.displayPath(for: RecordingsFolder.defaultFolder),
            action: #selector(useDefaultRecordingsFolder),
            keyEquivalent: ""
        )
        defaultFolderItem.target = self
        defaultFolderItem.state = recordingsFolder.isDefault ? .on : .off
        defaultFolderItem.isEnabled = !locked
        menu.addItem(defaultFolderItem)
        if !recordingsFolder.isDefault {
            let chosenFolderItem = NSMenuItem(
                title: recordingsFolder.displayPath,
                action: #selector(showRecordingsFolder),
                keyEquivalent: ""
            )
            chosenFolderItem.target = self
            chosenFolderItem.state = .on
            chosenFolderItem.toolTip = "Show this folder in Finder"
            chosenFolderItem.isEnabled = !locked
            menu.addItem(chosenFolderItem)
        }
        let chooseFolderItem = NSMenuItem(
            title: "Choose Recordings Folder…",
            action: #selector(chooseRecordingsFolder),
            keyEquivalent: ""
        )
        chooseFolderItem.target = self
        chooseFolderItem.isEnabled = !locked
        menu.addItem(chooseFolderItem)

        menu.addItem(.separator())
        let scriptItem = NSMenuItem(
            title: "Edit Teleprompter Script…",
            action: #selector(editTeleprompterScript),
            keyEquivalent: ""
        )
        scriptItem.target = self
        menu.addItem(scriptItem)
        let refreshItem = NSMenuItem(
            title: "Refresh Devices",
            action: #selector(refreshDevices),
            keyEquivalent: ""
        )
        refreshItem.target = self
        refreshItem.isEnabled = !locked
        menu.addItem(refreshItem)

        if needsPrivacySettings {
            let privacyItem = NSMenuItem(
                title: "Privacy Settings…",
                action: #selector(openPrivacySettings),
                keyEquivalent: ""
            )
            privacyItem.target = self
            menu.addItem(privacyItem)
        }

        return menu
    }

    private func disabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func cameraSelectedFromMenu(_ sender: NSMenuItem) {
        guard canConfigureOutput, let device = devices[safe: sender.tag] else { return }
        selectedCameraID = device.uniqueID
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        configureCapture(audioGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
    }

    @objc private func microphoneNoneSelected() {
        guard canConfigureOutput, !microphoneDisabled else { return }
        microphoneDisabled = true
        recorder.setMicrophoneIntentionallyDisabled(true)
        refreshAuthorizationAndConfigure(requestIfNeeded: false)
        updateRecordAvailability()
        statusLabel.stringValue = "Microphone off · the recording carries system audio only, or no audio at all"
    }

    @objc private func microphoneSelectedFromMenu(_ sender: NSMenuItem) {
        guard canConfigureOutput, let device = audioDevices[safe: sender.tag] else { return }
        microphoneDisabled = false
        recorder.setMicrophoneIntentionallyDisabled(false)
        selectedMicrophoneID = device.uniqueID
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        configureCapture(audioGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
    }

    private var needsPrivacySettings: Bool {
        [
            AVCaptureDevice.authorizationStatus(for: .video),
            AVCaptureDevice.authorizationStatus(for: .audio)
        ].contains { $0 != .authorized }
    }

    private func reloadDevices(preservingSelection: Bool = true) {
        let previousCameraID = preservingSelection ? selectedCameraID : nil
        let previousMicrophoneID = preservingSelection ? selectedMicrophoneID : nil
        devices = discoverVideoDevices()
        audioDevices = discoverAudioDevices()

        selectedCameraID = devices.first { $0.uniqueID == previousCameraID }?.uniqueID
            ?? devices.first { $0.uniqueID == AVCaptureDevice.systemPreferredCamera?.uniqueID }?.uniqueID
            ?? devices.first?.uniqueID
        selectedMicrophoneID = audioDevices.first { $0.uniqueID == previousMicrophoneID }?.uniqueID
            ?? audioDevices.first { $0.localizedName.localizedCaseInsensitiveContains("MacBook") }?.uniqueID
            ?? audioDevices.first?.uniqueID
    }

    private func refreshAuthorizationAndConfigure(requestIfNeeded: Bool) {
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        if videoStatus == .notDetermined, requestIfNeeded {
            statusLabel.stringValue = "Camera permission is required to start the preview…"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.reloadDevices()
                    self?.refreshAuthorizationAndConfigure(requestIfNeeded: true)
                }
            }
            return
        }

        guard videoStatus == .authorized else {
            setCaptureControlsEnabled(false)
            switch videoStatus {
            case .notDetermined:
                statusLabel.stringValue = "Camera access is not granted yet. Open the record menu → Privacy Settings…"
            case .denied:
                statusLabel.stringValue = "Camera access is off. Open the record menu → Privacy Settings…"
            case .restricted:
                statusLabel.stringValue = "Camera access is restricted on this Mac."
            case .authorized:
                break
            @unknown default:
                statusLabel.stringValue = "Camera permission state is unavailable."
            }
            return
        }

        if audioStatus == .notDetermined, requestIfNeeded {
            statusLabel.stringValue = "Camera allowed. Requesting optional microphone permission…"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.reloadDevices()
                    self?.refreshAuthorizationAndConfigure(requestIfNeeded: false)
                }
            }
            return
        }

        configureCapture(audioGranted: audioStatus == .authorized)
    }

    private func configureCapture(audioGranted: Bool) {
        guard let videoDevice = selectedCamera else {
            statusLabel.stringValue = "No camera found. Connect a camera or iPhone, then choose Refresh Devices in the record menu."
            setCaptureControlsEnabled(false)
            return
        }
        let audioDevice = audioGranted && !microphoneDisabled ? selectedMicrophone : nil
        configurationGeneration += 1
        let generation = configurationGeneration
        setCaptureControlsEnabled(false)
        statusLabel.stringValue = "Starting preview · \(videoDevice.localizedName)…"

        do {
            try recorder.configure(videoDevice: videoDevice, audioDevice: audioDevice)
            recorder.startSession { [weak self] isRunning in
                guard let self, generation == self.configurationGeneration else { return }
                self.setCaptureControlsEnabled(isRunning)
                if isRunning {
                    let audioSuffix = audioDevice.map { " · \($0.localizedName)" }
                        ?? (self.microphoneDisabled
                            ? " · microphone off"
                            : " · microphone permission required before recording")
                    let formatSuffix = self.recorder.activeCameraFormat
                        .map { " · \($0.width) × \($0.height)" } ?? ""
                    self.statusLabel.stringValue = "Preview active · \(videoDevice.localizedName)\(formatSuffix)\(audioSuffix)"
                } else {
                    self.statusLabel.stringValue = "Preview failed to start. Refresh devices or check Camera privacy settings."
                }
            }
        } catch {
            statusLabel.stringValue = "Capture setup failed: \(error.localizedDescription)"
            setCaptureControlsEnabled(false)
        }
    }

    private var selectedCamera: AVCaptureDevice? {
        devices.first { $0.uniqueID == selectedCameraID }
    }

    private var selectedMicrophone: AVCaptureDevice? {
        audioDevices.first { $0.uniqueID == selectedMicrophoneID }
    }

    /// Why Follow voice cannot hear the presenter right now, if anything: it
    /// listens to the selected microphone through the preview's session.
    private var followVoiceMicrophoneProblem: String? {
        if microphoneDisabled {
            return "It needs a microphone. Choose one in the record menu."
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return "It needs microphone access. Allow OneAct in Privacy & Security → Microphone."
        }
        guard selectedMicrophone != nil else {
            return "It needs a microphone. Connect one, then choose Refresh Devices in the record menu."
        }
        guard cameraSessionReady else {
            return "It starts listening once the camera preview is running."
        }
        return nil
    }

    private func setCaptureControlsEnabled(_ enabled: Bool) {
        cameraSessionReady = enabled
        zoomSlider.isEnabled = enabled
        recenterButton.isEnabled = enabled
        touchUpControl.isEditable = enabled && canConfigureComposition
        modeControl.isEnabled = enabled
        updateModeSpecificControls()
        updateRecordAvailability()
    }

    private func updateModeSpecificControls() {
        let screenMode = currentCaptureMode == .screenAndCamera
        let canConfigure = cameraSessionReady && canConfigureComposition
        let cropApplies = screenMode
            && screenLayoutControl.selectedSegment == ScreenLayoutMode.fill.rawValue
        chooseScreenButton.isEnabled = canConfigure && screenMode
        screenLayoutControl.isEnabled = canConfigure && screenMode
        screenAlignmentControl.isEnabled = canConfigure && cropApplies
        let style = currentCameraFrameStyle
        let cameraVisible = screenMode && style.showsCamera
        pipPositionControl.isEnabled = canConfigure && cameraVisible
        cameraSizeSlider.isEnabled = canConfigure && cameraVisible
        cameraFrameControl.isEnabled = canConfigure && screenMode
        mirrorButton.isEnabled = canConfigure && screenMode

        // Controls that do not apply to the current mode are collapsed, not just
        // dimmed, so the deck stays compact in camera-only mode.
        sourceGridRow?.isHidden = !screenMode
        screenGridRow?.isHidden = !screenMode
        overlayGridRow?.isHidden = !screenMode
        // Zoom only decides how much of the camera fills a frame. A cutout has
        // none, so the control would be a second size slider under another name.
        cameraZoomGroup?.isHidden = screenMode && !style.usesSoftwareZoom
        // A flip only means something when the person sits beside other
        // content. Camera-only recordings have nothing to be oriented against,
        // so the decision does not exist there — the same reason QuickTime's
        // recorder has no flip and its Edit menu does.
        cameraFlipGroup?.isHidden = !screenMode
        pipGroup?.isHidden = !cameraVisible
        cameraSizeGroup?.isHidden = !cameraVisible
        cameraFrameGroup?.isHidden = !screenMode
        cropGroup?.isHidden = !cropApplies
    }

    /// Size covers a wider range for a cutout, because it is the only control
    /// left for how big the person is once zoom drops out.
    private func updateCameraSizeRange(for style: CameraFrameStyle) {
        let limits = CameraOverlayScale.range(for: style)
        cameraSizeSlider.minValue = Double(limits.lowerBound)
        cameraSizeSlider.maxValue = Double(limits.upperBound)
        let clamped = CameraOverlayScale.clamp(cameraOverlayScale, for: style)
        cameraSizeSlider.doubleValue = Double(clamped)
        // The slider is the truth for the value the user can still reach, so a
        // cutout's 2.5× is pushed down to 1.6× when a framed style takes over
        // rather than leaving the overlay at a size the slider cannot express.
        if clamped != cameraOverlayScale {
            cameraOverlayScale = clamped
            recorder.setCameraOverlayScale(clamped)
        }
    }

    private func updateRecordAvailability() {
        let microphoneReady = microphoneDisabled
            || (AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                && selectedMicrophone != nil)
        audioMeter.inputAvailable = !microphoneDisabled
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && selectedMicrophone != nil
        if qualityCheckRunning {
            recordButton.isEnabled = false
            return
        }
        if recorder.isRecording {
            recordButton.isEnabled = true
            return
        }
        // No screen source is a valid composition — the camera over the canvas
        // colour — and it records as one, so it is no longer a precondition.
        // Requiring it only forced the picker on someone who meant to start
        // with the camera and share a window a minute in.
        recordButton.isEnabled = cameraSessionReady && microphoneReady
    }

    /// Composition can be re-set between the segments of one take. Pausing to
    /// go from a talking head to a screen share, reframe, and carry on is most
    /// of why pause is worth having — locking these while paused would leave
    /// the user pausing and then stopping anyway.
    private var canConfigureComposition: Bool {
        let state = reportRecordingState ?? (recorder.isRecording, recorder.isPaused)
        return !qualityCheckRunning && (!state.recording || state.paused)
    }

    /// What the file's shape depends on, which no pause can make safe to
    /// change: the canvas dimensions the writer was opened with, and the
    /// devices feeding it — another microphone can arrive at another sample
    /// rate, and the audio track's format was fixed when the file was created.
    private var canConfigureOutput: Bool {
        !qualityCheckRunning && !(reportRecordingState ?? (recorder.isRecording, recorder.isPaused)).recording
    }

    /// Stands in for the recorder's state under --layout-report, which renders
    /// the mid-take controls with no capture session behind them. The locking
    /// matrix is fiddly enough to want a check that does not need a camera.
    private var reportRecordingState: (recording: Bool, paused: Bool)?

    private func updateConfigurationAvailability() {
        if canConfigureOutput { applyCanvasOptions(announce: false) }
        let composition = canConfigureComposition
        modeControl.isEnabled = composition && cameraSessionReady
        captureOptionsButton.isEnabled = canConfigureOutput
        for button in ratioButtons { button.isEnabled = canConfigureOutput }
        for button in resolutionButtons { button.isEnabled = canConfigureOutput }
        recordingFormatControl.isEnabled = canConfigureOutput
        canvasBackdropWell.isEnabled = composition
        zoomSlider.isEnabled = composition && cameraSessionReady
        recenterButton.isEnabled = composition && cameraSessionReady
        cameraSizeSlider.isEnabled = composition && cameraSessionReady
        // Flipping mid-segment would swap the picture left to right inside one
        // continuous shot; flipping between segments is a shot change, which is
        // exactly what a pause is for.
        mirrorButton.isEnabled = composition && cameraSessionReady
        // A look that changed mid-segment would be a visible jump inside one
        // continuous shot, so touch-up locks with the rest of the composition.
        touchUpControl.isEditable = composition && cameraSessionReady
        videoEffectsButton.isEnabled = !qualityCheckRunning && cameraSessionReady
        updateModeSpecificControls()
    }

    private func discoverVideoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    private func discoverAudioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    @objc private func captureModeChanged() {
        let mode: CaptureMode = modeControl.selectedSegment == 1 ? .screenAndCamera : .cameraOnly
        currentCaptureMode = mode
        recorder.setCaptureMode(mode)
        previewView.setCaptureMode(mode)
        updateModeSpecificControls()
        if canConfigureOutput { applyCanvasOptions(announce: false) }
        updateCaptureQualityDescription()
        updateRecordAvailability()
        updateSystemAudioAvailability()

        // Mid-take the clock owns this line; overwriting it would drop the
        // elapsed time and the file name for a second every time the user
        // changes shot while paused.
        guard !recorder.isRecording else {
            updateRecordingClock()
            return
        }
        if mode == .screenAndCamera {
            statusLabel.stringValue = screenSourceReady
                ? "Screen + Camera ready · choose a Canvas and press Record"
                : "Choose a screen, application, or window, or record the camera over the canvas"
        } else {
            statusLabel.stringValue = "Camera mode ready"
        }
    }

    private var currentCanvas: CanvasPreset {
        appliedCanvas
    }

    private var requestedCanvas: CanvasPreset {
        CanvasOptions.preset(
            ratioIndex: selectedRatioIndex,
            resolutionIndex: selectedResolutionIndex
        )
    }

    private var currentCameraFrameStyle: CameraFrameStyle {
        CameraFrameStyle(rawValue: cameraFrameControl.selectedSegment) ?? .rectangle
    }

    private var currentPictureInPicturePosition: PictureInPicturePosition {
        PictureInPicturePosition(rawValue: pipPositionControl.selectedSegment) ?? .bottomRight
    }

    /// Where the person lands for a given target region, or nil when this is not
    /// a cutout or no person has been found yet.
    private func cutoutPlacement(region: CGRect, canvas: CanvasPreset) -> CutoutPlacement? {
        guard currentCameraFrameStyle == .cutout,
              let anchor = recorder.currentCutoutAnchor() else { return nil }
        return FrameCompositor.cutoutPlacement(
            cameraExtent: anchor.cameraExtent,
            personBox: anchor.personBox,
            region: region,
            canvasWidth: CGFloat(canvas.width),
            canvasHeight: CGFloat(canvas.height)
        )
    }

    /// Grabbing the camera overlay moves it; grabbing anywhere else pans the
    /// screen, which only has somewhere to pan in Fill layout.
    private func beginPreviewDrag(at point: CGPoint) {
        guard currentCaptureMode == .screenAndCamera, canConfigureComposition else { return }
        let canvas = currentCanvas
        let canvasWidth = CGFloat(canvas.width)
        let canvasHeight = CGFloat(canvas.height)
        let canvasPoint = CGPoint(x: point.x * canvasWidth, y: point.y * canvasHeight)
        let style = currentCameraFrameStyle
        let overlay = FrameCompositor.cameraOverlayFrame(
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            style: style,
            position: currentPictureInPicturePosition,
            origin: cameraOrigin,
            scale: cameraOverlayScale
        )

        // A cutout paints nothing but the person, so the person is what can be
        // grabbed — its box, not the invisible region it is aimed at. Dragging
        // still moves that region, and the person keeps following it.
        let grabArea = cutoutPlacement(region: overlay, canvas: canvas)?.personRect ?? overlay

        dragStartPoint = point
        if style.showsCamera, grabArea.contains(canvasPoint) {
            activeDrag = .camera
            dragStartCameraOrigin = overlay.origin
            statusLabel.stringValue = style == .cutout
                ? "Drag to place the person · a corner button snaps them back"
                : "Drag to place the camera · a corner button snaps it back"
            return
        }

        guard screenLayoutControl.selectedSegment == ScreenLayoutMode.fill.rawValue else {
            activeDrag = nil
            statusLabel.stringValue = screenSourceReady
                ? "Fit and Blur already show the whole screen · switch to Fill to pan it"
                : "Choose a screen, application, or window first"
            return
        }
        activeDrag = .screen
        dragStartScreenCropOffset = screenCropOffset
        statusLabel.stringValue = "Drag to pan the screen inside the canvas"
    }

    private func updatePreviewDrag(to point: CGPoint) {
        guard let activeDrag else { return }
        let canvas = currentCanvas
        let canvasWidth = CGFloat(canvas.width)
        let canvasHeight = CGFloat(canvas.height)

        switch activeDrag {
        case .camera:
            let origin = CGPoint(
                x: dragStartCameraOrigin.x + (point.x - dragStartPoint.x) * canvasWidth,
                y: dragStartCameraOrigin.y + (point.y - dragStartPoint.y) * canvasHeight
            )
            let clamped = FrameCompositor.cameraOverlayFrame(
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight,
                style: currentCameraFrameStyle,
                position: currentPictureInPicturePosition,
                origin: origin,
                scale: cameraOverlayScale
            )
            // A cutout's placement may push the person back inside the canvas.
            // Folding that correction into the stored origin keeps dragging
            // one-to-one: without it the region would keep sliding past the
            // point where the person can still move, and the drag would have to
            // travel back through that dead zone before anything happened.
            let settled = cutoutPlacement(region: clamped, canvas: canvas).map { placement in
                CGPoint(
                    x: clamped.minX + (placement.personRect.midX - clamped.midX),
                    y: clamped.minY + (placement.personRect.minY - clamped.minY)
                )
            } ?? clamped.origin
            cameraOrigin = settled
            recorder.setCameraOrigin(settled)
        case .screen:
            // Dragging owns the crop outright, so the Top/Center/Bottom preset
            // resets to Center instead of fighting the offset.
            let offset = CGPoint(
                x: min(max(dragStartScreenCropOffset.x - (point.x - dragStartPoint.x), -0.5), 0.5),
                y: min(max(dragStartScreenCropOffset.y - (point.y - dragStartPoint.y), -0.5), 0.5)
            )
            screenCropOffset = offset
            screenAlignmentControl.selectedSegment = ScreenVerticalAlignment.center.rawValue
            recorder.setScreenVerticalAlignment(.center)
            recorder.setScreenCropOffset(offset)
        }
    }

    @objc private func toggleTeleprompter() {
        let hadScript = teleprompter.hasScript
        teleprompter.toggle()
        statusLabel.stringValue = teleprompter.isVisible
            ? "Teleprompter on · click the script to edit it; it never appears in the recording"
            : "Teleprompter hidden"
        // Nothing to read yet, so start in edit mode straight away.
        if teleprompter.isVisible, !hadScript {
            teleprompter.beginEditing()
        }
    }

    @objc private func editTeleprompterScript() {
        if !teleprompter.isVisible {
            teleprompter.show()
        }
        teleprompter.beginEditing()
    }

    /// With a script on screen the presenter needs a beat before speaking, so
    /// recording starts after a countdown whenever the prompter is open.
    private func runCountdown(from seconds: Int, completion: @escaping () -> Void) {
        guard seconds > 0 else {
            countdownLabel.isHidden = true
            completion()
            return
        }
        countdownLabel.isHidden = false
        countdownLabel.stringValue = "\(seconds)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.runCountdown(from: seconds - 1, completion: completion)
        }
    }

    @objc private func stopScreenSharing() {
        screenCaptureController.stop()
        recorder.setScreenSourceActive(false)
        statusLabel.stringValue = "Screen sharing stopped · the camera stays in the canvas"
    }

    /// Live during recording on purpose: "only one segment wants the app's
    /// sound" was the founding request for this feature. Mixing is a gate, so
    /// flipping it mid-take is safe by construction.
    /// The source is a Core Audio process tap, independent of what is being
    /// shared — window shares, display shares, or no share at all. Creating
    /// the tap is what prompts for the System Audio Recording permission, so
    /// it happens here, on the user's own click, never at launch.
    @objc private func systemAudioToggled() {
        let enabled = systemAudioCheckbox.state == .on
        recorder.setSystemAudioEnabled(enabled)
        if enabled {
            systemAudioTap.start()
        } else {
            systemAudioTap.stop()
        }
        if recorder.isRecording {
            updateRecordingClock()
        } else {
            statusLabel.stringValue = enabled
                ? "System audio will be recorded · wear headphones if the sound plays out loud"
                : "System audio off · recording the microphone only"
        }
    }

    private func updateSystemAudioAvailability() {
        systemAudioCheckbox.toolTip = "Mix the sound playing on this Mac into the recording"
    }

    /// The tap failing to start is almost always a denied System Audio
    /// Recording permission, which macOS never re-prompts for. Without this
    /// the checkbox would sit checked while contributing silence.
    private func systemAudioFailedToStart(status: OSStatus) {
        systemAudioCheckbox.state = .off
        recorder.setSystemAudioEnabled(false)
        guard !recorder.isRecording else {
            updateRecordingClock()
            return
        }
        let alert = NSAlert()
        alert.messageText = "System Audio Is Not Available"
        alert.informativeText = "Recording system audio needs the System Audio Recording permission"
            + " (error \(status)). Enable OneAct under Screen & System Audio Recording in"
            + " System Settings, then try again.\n\nThe microphone keeps recording either way."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func chooseScreenSource() {
        guard currentCaptureMode == .screenAndCamera, canConfigureComposition else { return }
        statusLabel.stringValue = "Choose a display, application, or window in the macOS picker…"
        screenCaptureController.presentPicker()
    }

    @objc private func canvasBackdropColorChanged() {
        applyCanvasBackdrop(canvasBackdropWell.color, announce: true)
    }

    private func applyCanvasBackdrop(_ color: NSColor, announce: Bool) {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return }
        recorder.setCanvasBackdrop(CIColor(color: rgb) ?? .black)
        if let data = try? NSKeyedArchiver.archivedData(
            withRootObject: color,
            requiringSecureCoding: true
        ) {
            UserDefaults.standard.set(data, forKey: "canvas.backdropColor")
        }
        guard announce else { return }
        statusLabel.stringValue = String(
            format: "Canvas backdrop · R%.0f G%.0f B%.0f · recorded into the canvas",
            rgb.redComponent * 255,
            rgb.greenComponent * 255,
            rgb.blueComponent * 255
        )
    }

    private func storedCanvasBackdropColor() -> NSColor? {
        guard let data = UserDefaults.standard.data(forKey: "canvas.backdropColor") else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }

    /// Small dots parked at the right edge of the stage; they fade in on hover so
    /// the customisation never competes with the preview itself.
    private func makeStageBackdropDots() -> NSStackView {
        stageBackdropButtons = StageBackdropPreset.all.enumerated().map { index, preset in
            let button = NSButton(title: "", target: self, action: #selector(stageBackdropSelected(_:)))
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.tag = index
            button.toolTip = "\(preset.name) preview backdrop · app only, never recorded"
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
            button.layer?.backgroundColor = preset.color.cgColor
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 10).isActive = true
            button.heightAnchor.constraint(equalToConstant: 10).isActive = true
            return button
        }
        updateStageBackdropSelection()
        let stack = NSStackView(views: stageBackdropButtons)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7
        return stack
    }

    @objc private func stageBackdropSelected(_ sender: NSButton) {
        selectedStageBackdropIndex = sender.tag
        UserDefaults.standard.set(selectedStageBackdropIndex, forKey: "stage.backdropIndex")
        let preset = StageBackdropPreset.all[selectedStageBackdropIndex]
        previewStageView?.setBackdropColor(preset.color)
        updateStageBackdropSelection()
        statusLabel.stringValue = "Preview backdrop · \(preset.name) · app only, not recorded"
    }

    private func storedStageBackdropIndex() -> Int {
        let index = UserDefaults.standard.integer(forKey: "stage.backdropIndex")
        return (0..<StageBackdropPreset.all.count).contains(index) ? index : 0
    }

    private func updateStageBackdropSelection() {
        for (index, button) in stageBackdropButtons.enumerated() {
            let selected = index == selectedStageBackdropIndex
            button.layer?.borderWidth = selected ? 2 : 1
            button.layer?.borderColor = selected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.white.withAlphaComponent(0.35).cgColor
        }
    }

    @objc private func screenLayoutChanged() {
        guard let mode = ScreenLayoutMode(rawValue: screenLayoutControl.selectedSegment) else { return }
        recorder.setScreenLayoutMode(mode)
        updateModeSpecificControls()
        let message: String
        switch mode {
        case .fit:
            message = "Fit keeps the complete screen and may add black bars"
        case .fill:
            message = "Fill uses the full Canvas and crops overflow"
        case .blur:
            message = "Blur Background keeps the complete screen without empty black bars"
        }
        statusLabel.stringValue = message
    }

    @objc private func screenAlignmentChanged() {
        guard let alignment = ScreenVerticalAlignment(
            rawValue: screenAlignmentControl.selectedSegment
        ) else { return }
        screenCropOffset = .zero
        recorder.setScreenCropOffset(.zero)
        recorder.setScreenVerticalAlignment(alignment)
        statusLabel.stringValue = "Fill crop position set to \(alignment.label)"
    }

    @objc private func pictureInPicturePositionControlChanged() {
        guard let position = PictureInPicturePosition(
            rawValue: pipPositionControl.selectedSegment
        ) else { return }
        cameraOrigin = nil
        recorder.setCameraOrigin(nil)
        recorder.setPictureInPicturePosition(position)
        statusLabel.stringValue = "Camera position set to \(position.label) · drag the camera to place it freely"
    }

    @objc private func cameraFrameStyleChanged() {
        guard let style = CameraFrameStyle(rawValue: cameraFrameControl.selectedSegment) else { return }
        recorder.setCameraFrameStyle(style)
        updateCameraSizeRange(for: style)
        updateModeSpecificControls()
        statusLabel.stringValue = "Camera frame · \(style.detail)"
    }

    @objc private func cameraChanged() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        configureCapture(audioGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
    }

    @objc private func microphoneChanged() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        configureCapture(audioGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
    }

    @objc private func refreshDevices() {
        reloadDevices()
        refreshAuthorizationAndConfigure(requestIfNeeded: false)
    }

    @objc private func openPrivacySettings() {
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if videoStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.reloadDevices()
                    self?.refreshAuthorizationAndConfigure(requestIfNeeded: true)
                }
            }
            return
        }
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if videoStatus == .authorized && audioStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.reloadDevices()
                    self?.refreshAuthorizationAndConfigure(requestIfNeeded: false)
                }
            }
            return
        }
        let pane = videoStatus == .denied || videoStatus == .restricted
            ? "Privacy_Camera"
            : "Privacy_Microphone"
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func canvasRatioSelected(_ sender: CanvasPresetButton) {
        guard canConfigureOutput else { return }
        selectedRatioIndex = sender.presetIndex
        for button in ratioButtons {
            button.setSelected(button.presetIndex == selectedRatioIndex)
        }
        applyCanvasOptions()
    }

    @objc private func canvasResolutionSelected(_ sender: CanvasPresetButton) {
        guard canConfigureOutput else { return }
        selectedResolutionIndex = sender.presetIndex
        for button in resolutionButtons {
            button.setSelected(button.presetIndex == selectedResolutionIndex)
        }
        applyCanvasOptions()
    }

    @objc private func recordingFormatChanged() {
        guard canConfigureOutput,
              let format = VideoRecordingFormat.allCases[safe: recordingFormatControl.selectedSegment] else { return }
        applyRecordingFormat(format, persist: true)
        statusLabel.stringValue = "\(format.label) · \(format.detail)"
    }

    private func applyRecordingFormat(_ format: VideoRecordingFormat, persist: Bool) {
        selectedRecordingFormat = format
        recorder.setRecordingFormat(format)
        recordingFormatControl.selectedSegment = VideoRecordingFormat.allCases.firstIndex(of: format) ?? 0
        recordingFormatDetail.stringValue = format.detail
        if persist { UserDefaults.standard.set(format.rawValue, forKey: "recording.videoFormat") }
    }

    private func applyCanvasOptions(announce: Bool = true) {
        guard canConfigureOutput else { return }
        var preset = requestedCanvas
        if currentCaptureMode == .cameraOnly, let state = cameraCaptureState {
            let size = CameraOutputSizing.limited(
                width: preset.width, height: preset.height,
                sourceWidth: state.width, sourceHeight: state.height,
                zoom: CGFloat(zoomSlider.doubleValue)
            )
            preset = CanvasPreset(name: preset.name, width: size.width, height: size.height)
        }
        if preset != appliedCanvas {
            appliedCanvas = preset
            recorder.setCanvas(preset)
        }
        updatePreviewSize(for: preset)
        outputSizeLabel.stringValue = "\(preset.width) × \(preset.height)"
        updateCaptureQualityDescription()
        if announce {
            statusLabel.stringValue = "Canvas set to \(preset.label)"
        }
    }

    @objc private func cameraSizeChanged() {
        let style = currentCameraFrameStyle
        let scale = CameraOverlayScale.clamp(CGFloat(cameraSizeSlider.doubleValue), for: style)
        cameraOverlayScale = scale
        recorder.setCameraOverlayScale(scale)
        statusLabel.stringValue = style == .cutout
            ? String(format: "Person size %.0f%% · drag the person to place them", scale * 100)
            : String(
                format: "Camera size %.0f%% · zoom changes what the camera shows, size changes how big the overlay is",
                scale * 100
            )
    }

    @objc private func zoomChanged() {
        applySoftwareZoom(CGFloat(zoomSlider.doubleValue), announce: true)
    }

    @objc private func cameraMirrorChanged() {
        cameraMirrored = mirrorButton.state == .on
        recorder.setCameraMirrored(cameraMirrored)
        statusLabel.stringValue = cameraMirrored
            ? "Camera flipped left to right · preview and recording both"
            : "Camera flip off · recorded as the camera sees it"
    }

    private func applyTouchUp(_ settings: TouchUpSettings, announce: Bool) {
        recorder.touchUp.update(settings)
        previewView.setComposedCameraPreview(settings.isActive)
        if announce { statusLabel.stringValue = touchUpControl.statusText }
    }

    @objc private func recenterZoom() {
        zoomSlider.doubleValue = 1
        applySoftwareZoom(1, announce: true)
    }

    private func applySoftwareZoom(_ zoom: CGFloat, announce: Bool) {
        let clampedZoom = max(1, min(zoom, 3))
        previewView.setSoftwareZoom(clampedZoom)
        recorder.setSoftwareZoom(clampedZoom)
        zoomValueLabel.stringValue = String(format: "%.1f×", clampedZoom)
        if canConfigureOutput { applyCanvasOptions(announce: false) }
        updateCaptureQualityDescription()
        if announce {
            statusLabel.stringValue = String(
                format: "Software Zoom %.1f× · applied to preview and recording",
                clampedZoom
            )
        }
    }

    private func updateCaptureQualityDescription() {
        guard let state = cameraCaptureState else { return }
        let output = currentCanvas
        let limited = currentCaptureMode == .cameraOnly
            && (output.width < requestedCanvas.width || output.height < requestedCanvas.height)
        let upscaled = modeControl.selectedSegment == 0 && state.requiresUpscaling(
            width: output.width, height: output.height, zoom: CGFloat(zoomSlider.doubleValue)
        )
        outputSizeLabel.stringValue = "\(output.width) × \(output.height)" + (limited ? " · camera limit" : (upscaled ? " · upscaled" : ""))
        outputSizeLabel.toolTip = "Camera input: \(state.width) × \(state.height). Output: \(output.width) × \(output.height)."
            + (limited ? " Camera-only output is limited to the pixels available after crop and zoom." : "")
            + (upscaled ? " Enlarging the canvas does not add camera detail." : "")
    }

    private func updatePreviewSize(for preset: CanvasPreset) {
        // The preview keeps the canvas aspect ratio and grows with the stage,
        // so resizing the window gives the picture the extra space.
        let aspect = CGFloat(preset.width) / CGFloat(preset.height)
        previewAspectConstraint?.isActive = false
        let aspectConstraint = previewView.widthAnchor.constraint(
            equalTo: previewView.heightAnchor,
            multiplier: aspect
        )
        aspectConstraint.isActive = true
        previewAspectConstraint = aspectConstraint
        previewView.superview?.needsLayout = true
    }

    @objc private func toggleRecording() {
        guard !qualityCheckRunning else { return }
        if recorder.isRecording {
            recordButton.isEnabled = false
            let takeLength = recordedClockText
            let takeFolder = activeTakeFolder
            activeTakeFolder = nil
            endRecordingClock()
            teleprompter.stopScrolling()
            teleprompter.unlockAfterRecording()
            recorder.stopRecording { [weak self] result in
                guard let self else { return }
                self.recordButton.setRecordingAppearance(false)
                self.updateConfigurationAvailability()
                self.updateRecordAvailability()
                self.updatePauseAffordances()
                switch result {
                case .success(let outcome):
                    let path = RecordingsFolder.displayPath(for: outcome.url)
                    if outcome.hasAudio {
                        self.statusLabel.stringValue = "Saved with audio · \(path)"
                    } else if self.microphoneDisabled && self.systemAudioCheckbox.state == .off {
                        // Exactly what was asked for; warning about it would
                        // teach people to ignore the warning that matters.
                        self.statusLabel.stringValue = "Saved (video only) · \(path)"
                    } else {
                        self.statusLabel.stringValue = "Warning: saved without audio samples · \(path)"
                    }
                    if let missing = self.recordingsFolder.takeUnavailableNotice() {
                        self.statusLabel.stringValue += " · “\(missing)” was unavailable, so it went to Movies"
                    }
                    // The card replaces revealing every take in Finder, which
                    // pulled Finder in front of the app after each recording.
                    self.presentRecordingCard(
                        url: outcome.url,
                        length: takeLength,
                        folder: takeFolder ?? self.recordingsFolder.current
                    )
                case .failure(let error):
                    self.statusLabel.stringValue = "Recording failed: \(error.localizedDescription)"
                }
            }
        } else {
            let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            guard microphoneDisabled || (audioStatus == .authorized && selectedMicrophone != nil) else {
                if audioStatus == .notDetermined {
                    statusLabel.stringValue = "Microphone permission is required. Approve the macOS prompt, then click Record again."
                    AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                        DispatchQueue.main.async {
                            self?.reloadDevices()
                            self?.refreshAuthorizationAndConfigure(requestIfNeeded: false)
                        }
                    }
                } else if audioStatus == .denied || audioStatus == .restricted {
                    statusLabel.stringValue = "Microphone access is off. Enable OneAct in Privacy & Security → Microphone."
                } else {
                    statusLabel.stringValue = "No microphone is selected. Connect or select a microphone, then click Record again."
                }
                return
            }
            guard !takeStarting else { return }
            // Starting the next take keeps the last one: the card goes, the
            // file stays where it was saved.
            dismissRecordingCard()
            // The folder is settled before Record is pressed, so pressing it
            // starts the take — no save panel between deciding to speak and
            // speaking, and none in front of every retake.
            let destination: RecordingsFolder.Destination
            do {
                destination = try recordingsFolder.nextDestination(timestamp: timestamp())
            } catch {
                statusLabel.stringValue = "Can't save to \(recordingsFolder.displayPath): \(error.localizedDescription) · choose another folder from the record menu"
                return
            }
            let url = destination.url
            activeTakeFolder = destination.folder
            takeStarting = true
            recordButton.isEnabled = false
            teleprompter.lockForRecording()
            // An open teleprompter means the presenter is about to read, so
            // recording waits out a countdown and the script starts rolling
            // together with the first frame.
            let leadIn = teleprompter.isVisible ? 3 : 0
            statusLabel.stringValue = leadIn > 0 ? "Starting in \(leadIn)…" : "Starting…"
            runCountdown(from: leadIn) { [weak self] in
                guard let self else { return }
                self.countdownLabel.isHidden = true
                self.recorder.startRecording(to: url) { result in
                    self.takeStarting = false
                    switch result {
                    case .success:
                        self.updateConfigurationAvailability()
                        self.recordButton.setRecordingAppearance(true)
                        self.recordButton.isEnabled = true
                        self.teleprompter.startScrolling()
                        self.beginRecordingClock(fileName: url.lastPathComponent)
                        self.updatePauseAffordances()
                    case .failure(let error):
                        self.activeTakeFolder = nil
                        self.teleprompter.unlockAfterRecording()
                        self.updateConfigurationAvailability()
                        self.updateRecordAvailability()
                        self.statusLabel.stringValue = "Recording failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    /// Renders the Touch-up popover's content into its own PNG and pins a copy
    /// above its button in the main render: a popover is a separate window,
    /// which an off-screen render of the main window would otherwise miss.
    private func writeTouchUpReport(outputPath: String, in contentView: NSView) {
        guard let bitmap = touchUpControl.reportSnapshot() else {
            print("TOUCH_UP_POPOVER missing")
            return
        }
        if let data = bitmap.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: outputPath).deletingPathExtension().appendingPathExtension("touchup.png")
            try? data.write(to: url)
        }
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        let button = touchUpControl.button
        let anchor = button.convert(button.bounds, to: contentView)
        let snapshot = NSImageView(frame: NSRect(
            x: min(max(8, anchor.midX - bitmap.size.width / 2), contentView.bounds.width - bitmap.size.width - 8),
            y: anchor.maxY + 6,
            width: bitmap.size.width,
            height: bitmap.size.height
        ))
        snapshot.image = image
        contentView.addSubview(snapshot)
        print("TOUCH_UP_POPOVER size=\(bitmap.size) anchor=\(anchor)")
    }

    // MARK: Finished take

    private func wireRecordingCard() {
        recordingCard.onPlay = { [weak self] in self?.playPresentedRecording() }
        recordingCard.onRename = { [weak self] name in
            self?.renamePresentedRecording(to: name) ?? .failure(CocoaError(.fileNoSuchFile))
        }
        recordingCard.onShowInFinder = { [weak self] in
            guard let url = self?.presentedRecording?.url else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        recordingCard.onDiscard = { [weak self] in self?.discardPresentedRecording() }
        recordingCard.onDismiss = { [weak self] in self?.dismissRecordingCard() }
    }

    private func presentRecordingCard(url: URL, length: String, folder: RecordingsFolder.Access) {
        // A take that finished writing after the next one began — stop and
        // start back to back on the hotkey — is saved; it just gets no card.
        guard !takeStarting, !recorder.isRecording else { return }
        presentedRecording = (url, folder)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        let detail = [
            length,
            bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
            RecordingsFolder.displayPath(for: url.deletingLastPathComponent())
        ].compactMap { $0 }.joined(separator: " · ")
        recordingCard.show(url: url, detail: detail)
    }

    /// Closing the card keeps the file; only Discard & Retake removes it.
    private func dismissRecordingCard() {
        closeRecordingPreview()
        recordingCard.hide()
        presentedRecording = nil
    }

    private func renamePresentedRecording(to proposedName: String) -> Result<URL, Error> {
        guard let (current, folder) = presentedRecording else { return .failure(CocoaError(.fileNoSuchFile)) }
        do {
            let renamed = try RecordingsFolder.rename(current, to: proposedName)
            presentedRecording = (renamed, folder)
            reloadRecordingPreview()
            statusLabel.stringValue = "Renamed · \(RecordingsFolder.displayPath(for: renamed))"
            return .success(renamed)
        } catch {
            statusLabel.stringValue = "Rename failed: \(error.localizedDescription)"
            return .failure(error)
        }
    }

    /// The retake path: the flubbed take goes to the Trash — recoverable with
    /// Put Back, never deleted outright — and the recorder is ready again.
    private func discardPresentedRecording() {
        guard let url = presentedRecording?.url else { return }
        closeRecordingPreview()
        do {
            try RecordingsFolder.moveToTrash(url)
        } catch {
            statusLabel.stringValue = "Couldn't move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)"
            return
        }
        dismissRecordingCard()
        updateRecordAvailability()
        statusLabel.stringValue = "Moved \(url.lastPathComponent) to the Trash · ready for the retake (⌥⌘R)"
    }

    private func playPresentedRecording() {
        guard presentedRecording != nil, let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func reloadRecordingPreview() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.reloadData()
    }

    /// A preview still playing when the next take starts would be recorded
    /// by the microphone.
    private func closeRecordingPreview() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.orderOut(nil)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }

    // MARK: Recordings folder

    @objc private func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "New recordings are saved here. Record starts straight away, without asking."
        panel.directoryURL = recordingsFolder.current.url
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if RecordingsFolder.isDefaultFolder(url) {
                self.useDefaultRecordingsFolder()
                return
            }
            do {
                try self.recordingsFolder.choose(url)
                self.statusLabel.stringValue = "New recordings save to \(self.recordingsFolder.displayPath)"
            } catch {
                self.statusLabel.stringValue = "Couldn't use \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if let window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: apply)
        } else {
            panel.begin(completionHandler: apply)
        }
    }

    @objc private func useDefaultRecordingsFolder() {
        recordingsFolder.resetToDefault()
        statusLabel.stringValue = "New recordings save to \(recordingsFolder.displayPath)"
    }

    @objc private func showRecordingsFolder() {
        let folder = recordingsFolder.current.url
        // The default folder only exists after the first take.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Renders the teleprompter panel off-screen and reports the window
    /// properties that keep it out of recordings.
    private func writePrompterReport(outputPath: String) {
        guard let panel = NSApp.windows.first(where: { $0.sharingType == .none }),
              let contentView = panel.contentView else {
            print("PROMPTER_REPORT panel missing")
            return
        }
        panel.layoutIfNeeded()
        print("PROMPTER_REPORT size=\(contentView.frame.size) sharingType=\(panel.sharingType.rawValue) child=\(panel.parent === window) canBecomeKey=\(panel.canBecomeKey)")
        // Exercise the in-place edit cycle: begin, then commit with unchanged
        // text — states must flip and no saved script may be fabricated.
        teleprompter.beginEditing()
        // Same slider position must mean the same speaking pace in both scripts.
        let chineseSample = String(repeating: "这是一段中文稿件用来校准语速", count: 10)
        let englishSample = String(
            repeating: "this is an english script used to calibrate the pace ",
            count: 10
        )
        print("PROMPTER_PACE zh_chars=\(chineseSample.count) zh_units=\(TeleprompterController.estimatedWordCount(of: chineseSample)) en_units=\(TeleprompterController.estimatedWordCount(of: englishSample))")
        let curve = [0.0, 0.25, 0.5, 0.75, 1.0]
            .map { String(format: "%.0f%%=%.0f", $0 * 100, TeleprompterLimits.speed(forSliderValue: $0)) }
            .joined(separator: " ")
        print("PROMPTER_SLIDER_CURVE \(curve)")
        // Measure what the top of the slider actually delivers for a Chinese
        // script — via the non-persisting setter, and restored afterwards.
        let originalScript = teleprompter.script
        teleprompter.setScriptForDiagnostics(chineseSample)
        for setting in [130.0, TeleprompterLimits.maximumWordsPerMinute] {
            teleprompter.setSpeedForDiagnostics(setting)
            let pace = teleprompter.paceDiagnostics()
            print(String(
                format: "PROMPTER_MEASURED wpm=%.0f doc=%.0f visible=%.0f units=%d seconds=%.1f chars_per_min=%.0f",
                setting, pace.documentHeight, pace.visibleHeight, pace.units, pace.secondsToEnd, pace.charactersPerMinute
            ))
        }
        teleprompter.setScriptForDiagnostics(originalScript)
        print("PROMPTER_EDIT begin editing=\(teleprompter.isEditing) playEnabled=\(teleprompter.playControlEnabled)")
        teleprompter.commitEditing()
        print("PROMPTER_EDIT commit editing=\(teleprompter.isEditing) playEnabled=\(teleprompter.playControlEnabled) hasScript=\(teleprompter.hasScript)")
        func renderPanel(suffix: String) {
            panel.layoutIfNeeded()
            guard let representation = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { return }
            contentView.cacheDisplay(in: contentView.bounds, to: representation)
            if let data = representation.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: outputPath)
                    .deletingPathExtension()
                    .appendingPathExtension(suffix)
                try? data.write(to: url)
            }
        }
        // Default bar: the Follow voice toggle, off, beside the speed slider.
        // Neither state is persisted and no recognition starts.
        teleprompter.setFollowVoiceForDiagnostics(false)
        print("PROMPTER_FOLLOW off \(teleprompter.followVoiceDiagnostics)")
        renderPanel(suffix: "prompter.png")
        // Follow voice on: language and status replace the slider, and the
        // part already spoken is dimmed above the reading line.
        teleprompter.setScriptForDiagnostics(PrompterFollowSimulation.sampleScript)
        let readingOffset = teleprompter.setFollowVoiceForDiagnostics(true, spokenFraction: 0.4) ?? -1
        print("PROMPTER_FOLLOW on \(teleprompter.followVoiceDiagnostics) reading_offset=\(Int(readingOffset)) \(teleprompter.followGeometryDiagnostics())")
        renderPanel(suffix: "prompter-follow.png")
        print("PROMPTER_FOLLOW_SIM \(teleprompter.followSimulationDiagnostics())")
        teleprompter.setFollowVoiceForDiagnostics(false)
        teleprompter.setScriptForDiagnostics(originalScript)
    }

    @objc private func togglePause() {
        guard !qualityCheckRunning, recorder.isRecording else { return }
        if recorder.isPaused {
            recorder.resumeRecording()
            if let began = pauseBeganAt {
                pausedAccumulated += Date().timeIntervalSince(began)
                pauseBeganAt = nil
            }
            // Resumes from where it stopped; the restart only re-arms the ease-in,
            // which is what a speaker picking the thread back up wants anyway.
            teleprompter.startScrolling()
        } else {
            recorder.pauseRecording()
            pauseBeganAt = Date()
            // A script that keeps scrolling through a pause would be several
            // lines ahead of the speaker by the time the take resumes.
            teleprompter.stopScrolling()
        }
        updatePauseAffordances()
        updateRecordingClock()
    }

    /// Both buttons and the menu bar read from the recorder's own state rather
    /// than a mirrored flag, so they cannot disagree with what is being written.
    private func updatePauseAffordances() {
        let recording = recorder.isRecording
        let paused = recording && recorder.isPaused
        pauseButton.isHidden = !recording
        pauseButtonWidth.constant = recording ? Self.pauseButtonWidth : 0
        pauseButtonTrailing.constant = recording ? -8 : 0
        setPauseButtonTitle(paused: paused)
        pausedBadge.isHidden = !paused
        recordButton.setPausedAppearance(paused)
        updateConfigurationAvailability()
        updateStatusItem()
    }

    private static let pauseButtonWidth: CGFloat = 96

    /// Plain words on the button; the keys are in the tooltip, the status
    /// line during a take, and the Recording menu.
    private func setPauseButtonTitle(paused: Bool) {
        pauseButton.title = paused ? "Resume" : "Pause"
        let action = paused ? "Resume recording" : "Pause recording"
        pauseButton.toolTip = pauseHotKeyRegistered
            ? "\(action) (Space, or ⌥⌘P from any app)"
            : "\(action) (Space or ⌥⌘P)"
    }

    private func beginRecordingClock(fileName: String) {
        recordingStartDate = Date()
        pausedAccumulated = 0
        pauseBeganAt = nil
        recordingTimer?.invalidate()
        recordingFileName = fileName
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateRecordingClock() }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
        updateRecordingClock()
    }

    /// Seconds actually written, which is wall-clock time minus every pause —
    /// including one still open. The label has to match the file it describes,
    /// or a four-minute session with a one-minute pause would promise four
    /// minutes of footage and deliver three.
    private var recordedSeconds: Int {
        guard let start = recordingStartDate else { return 0 }
        var pausedSoFar = pausedAccumulated
        if let began = pauseBeganAt { pausedSoFar += Date().timeIntervalSince(began) }
        return max(0, Int(Date().timeIntervalSince(start) - pausedSoFar))
    }

    private var recordedClockText: String {
        let seconds = recordedSeconds
        return seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func updateRecordingClock() {
        guard recordingStartDate != nil else { return }
        // Recording the bare canvas is legitimate but rarely intended for long,
        // so it is named in the one line that is on screen the whole time
        // rather than left for the user to discover in the file.
        let sourceNote = currentCaptureMode == .screenAndCamera && !screenSourceReady
            ? " · no screen source"
            : ""
        let audioNote = systemAudioCheckbox.state == .on ? " · system audio" : ""
        statusLabel.stringValue = Self.recordingStatusLine(
            paused: recorder.isPaused,
            clock: recordedClockText,
            notes: sourceNote + audioNote,
            fileName: recordingFileName
        )
        updateStatusItem()
    }

    /// The one line on screen for the whole take, ending with the key for the
    /// next pause or resume. The label truncates in the middle, so a long
    /// file name gives way before the hint does.
    private static func recordingStatusLine(paused: Bool, clock: String, notes: String, fileName: String) -> String {
        paused
            ? "❙❙ Paused \(clock)\(notes) · \(fileName) · Space to resume"
            : "● Recording \(clock)\(notes) · \(fileName) · Space to pause"
    }

    private func endRecordingClock() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartDate = nil
        pausedAccumulated = 0
        pauseBeganAt = nil
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// Website fixtures use a fixed 2× scale, independent of the connected display.
    private func layoutBitmap(for view: NSView) -> NSBitmapImageRep? {
        guard CommandLine.arguments.contains("--demo-scene") else {
            return view.bitmapImageRepForCachingDisplay(in: view.bounds)
        }
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * 2),
            pixelsHigh: Int(view.bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )
        bitmap?.size = view.bounds.size
        return bitmap
    }

    /// Renders the main window off-screen and writes it to `outputPath`, so the
    /// layout can be checked without camera, microphone, or screen permissions.
    func writeLayoutReport(outputPath: String, screenMode: Bool, minimumSize: Bool) {
        if CommandLine.arguments.contains("--onboarding") {
            // The permission page is normally only reachable before access is
            // granted, so render it on demand.
            let onboarding = PermissionOnboardingController {}
            guard let contentView = onboarding.window.contentView else { return }
            onboarding.window.layoutIfNeeded()
            print("ONBOARDING_REPORT size=\(contentView.frame.size) ambiguous=\(contentView.hasAmbiguousLayout)")
            if let representation = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) {
                contentView.cacheDisplay(in: contentView.bounds, to: representation)
                if let data = representation.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: outputPath))
                }
            }
            return
        }
        enterMainInterface()
        if CommandLine.arguments.contains("--prores") { applyRecordingFormat(.proRes422, persist: false) }
        if screenMode {
            modeControl.selectedSegment = 1
            captureModeChanged()
            chooseScreenButton.title = "Add Windows…"
            stopScreenButton.isHidden = false
            if CommandLine.arguments.contains("--cutout") {
                cameraFrameControl.selectedSegment = CameraFrameStyle.cutout.rawValue
                cameraFrameStyleChanged()
            }
        }
        statusLabel.stringValue = "Preview active · sample camera · sample microphone"
        cameraSessionReady = true
        updateConfigurationAvailability()
        recordButton.isEnabled = true
        if CommandLine.arguments.contains("--stage-dots") {
            // Skip the fade so the off-screen render catches them.
            stageBackdropDots?.alphaValue = 1
        }
        print("STAGE_BACKDROP presets=\(StageBackdropPreset.all.count) selected=\(selectedStageBackdropIndex) canvasWell=\(canvasBackdropWell.colorWellStyle == .expanded ? "expanded" : "other")")
        if CommandLine.arguments.contains("--touch-up") {
            var settings = TouchUpSettings.defaults
            settings.enabled = true
            touchUpControl.set(settings)
        }
        print("OVERLAY_DECK frame=\(currentCameraFrameStyle.label) zoom=\((cameraZoomGroup?.isHidden ?? false) ? "hidden" : "visible") flip=\((cameraFlipGroup?.isHidden ?? false) ? "hidden" : "visible") size=\(cameraSizeSlider.minValue)–\(cameraSizeSlider.maxValue)")
        // The recording row is only reachable with a live capture session, so
        // render it on demand: it is the one layout where a control appears
        // mid-session and can push the others out of place.
        if CommandLine.arguments.contains("--recording") {
            recordButton.setRecordingAppearance(true)
            let paused = CommandLine.arguments.contains("--paused")
            reportRecordingState = (recording: true, paused: paused)
            // Most composition controls are also gated on a live preview, which
            // an off-screen render has no way to start; without this the report
            // could not tell "locked mid-take" from "no camera yet".
            cameraSessionReady = true
            updateConfigurationAvailability()
            pauseButton.isHidden = false
            pauseButtonWidth.constant = Self.pauseButtonWidth
            pauseButtonTrailing.constant = -8
            setPauseButtonTitle(paused: paused)
            pausedBadge.isHidden = !paused
            recordButton.setPausedAppearance(paused)
            audioMeter.inputAvailable = true
            statusLabel.stringValue = Self.recordingStatusLine(
                paused: paused,
                clock: "01:12",
                notes: "",
                fileName: "OneAct-20260813-030405.mov"
            )
        }
        // The card only appears after a real take, so render it on demand.
        // The sample file does not exist — the card falls back to the movie
        // icon — and no take is recorded as presented, so the card's actions
        // find nothing on disk to act on.
        if CommandLine.arguments.contains("--saved-card") {
            let sample = RecordingsFolder.defaultFolder.appendingPathComponent("OneAct-20260813-030405.mov")
            recordingCard.show(url: sample, detail: "01:12 · 48.2 MB · \(RecordingsFolder.displayPath(for: RecordingsFolder.defaultFolder))")
            statusLabel.stringValue = "Saved with audio · \(RecordingsFolder.displayPath(for: sample))"
        }
        if minimumSize {
            window.setContentSize(window.minSize)
        }
        guard let contentView = window.contentView else { return }
        window.layoutIfNeeded()
        if CommandLine.arguments.contains("--saved-card") {
            if CommandLine.arguments.contains("--renaming") {
                recordingCard.beginRenaming()
                window.layoutIfNeeded()
            }
            let stageBounds = previewStageView?.bounds ?? .zero
            let cardFrame = recordingCard.frame
            print("SAVED_CARD frame=\(cardFrame) insideStage=\(stageBounds.insetBy(dx: 15, dy: 15).contains(cardFrame)) renaming=\(recordingCard.isRenaming) ambiguous=\(recordingCard.hasAmbiguousLayout) actions=\(recordingCard.buttonTitles)")
            for button in [recordingCard.playButton, recordingCard.renameButton, recordingCard.finderButton, recordingCard.discardButton] {
                let clipped = button.frame.width < button.intrinsicContentSize.width - 0.5
                print("SAVED_CARD_BUTTON \(button.title) width=\(Int(button.frame.width)) clipped=\(clipped)")
            }
        } else {
            print("SAVED_CARD hidden=\(recordingCard.isHidden)")
        }
        if let demoFlag = CommandLine.arguments.firstIndex(of: "--demo-scene") {
            guard CommandLine.arguments.indices.contains(demoFlag + 1),
                  let demoImage = NSImage(contentsOfFile: CommandLine.arguments[demoFlag + 1]) else {
                fputs("LAYOUT_REPORT_FAILED: --demo-scene requires a readable image path.\n", stderr)
                Darwin.exit(1)
            }
            // Presentation-only fixture: no camera or screen is captured. An
            // NSImageView keeps the actual controls and their text unmodified.
            let demoView = NSImageView(frame: previewView.bounds)
            demoView.image = demoImage
            demoView.imageScaling = .scaleProportionallyUpOrDown
            demoView.autoresizingMask = [.width, .height]
            previewView.addSubview(demoView)
            stageBackdropDots?.alphaValue = 0
            statusLabel.stringValue = "Demo scene · illustrated presenter · no live capture"
        }
        if CommandLine.arguments.contains("--prompter") {
            if CommandLine.arguments.contains("--demo-scene") {
                teleprompter.setScriptForDiagnostics("""
                Let's turn an idea into one take.

                Share your screen. Tell your story.

                Keep your notes close, and your eyes on the camera.
                """)
            }
            teleprompter.show()
            if CommandLine.arguments.contains("--demo-scene") {
                // The prompter is a separate, non-shareable child window.
                // Render its real AppKit view into the website fixture only;
                // the recording compositor never includes this overlay.
                guard let panel = window.childWindows?.first(where: { $0.sharingType == .none }),
                      let panelView = panel.contentView else {
                    fputs("LAYOUT_REPORT_FAILED: demo teleprompter is missing.\n", stderr)
                    Darwin.exit(1)
                }
                panel.layoutIfNeeded()
                guard let panelBitmap = layoutBitmap(for: panelView) else {
                    fputs("LAYOUT_REPORT_FAILED: could not render demo teleprompter.\n", stderr)
                    Darwin.exit(1)
                }
                panelView.cacheDisplay(in: panelView.bounds, to: panelBitmap)
                let panelImage = NSImage(size: panelView.bounds.size)
                panelImage.addRepresentation(panelBitmap)
                let panelFrame = contentView.convert(window.convertFromScreen(panel.frame), from: nil)
                let panelSnapshot = NSImageView(frame: panelFrame)
                panelSnapshot.image = panelImage
                panelSnapshot.imageScaling = .scaleAxesIndependently
                contentView.addSubview(panelSnapshot)
                print("DEMO_PROMPTER sharingType=\(panel.sharingType.rawValue) child=\(panel.parent === window) frame=\(panelFrame)")
            } else {
                writePrompterReport(outputPath: outputPath)
            }
        }
        if CommandLine.arguments.contains("--touch-up") {
            writeTouchUpReport(outputPath: outputPath, in: contentView)
        }
        print("LAYOUT_REPORT size=\(contentView.frame.size) ambiguous=\(contentView.hasAmbiguousLayout)")
        if CommandLine.arguments.contains("--recording") {
            let stage = pausedBadge.superview?.bounds ?? .zero
            print("PAUSED_BADGE visible=\(!pausedBadge.isHidden) frame=\(pausedBadge.frame) insideStage=\(stage.insetBy(dx: 15, dy: 15).contains(pausedBadge.frame)) ambiguous=\(pausedBadge.hasAmbiguousLayout) text=\"\(pausedBadge.reportText)\"")
            print("SPACE_PAUSE \(spacePauseReport())")
        }
        print("SHORTCUT_HINTS record=\"\(recordButton.title)\" recordTip=\"\(recordButton.toolTip ?? "")\" pause=\"\(pauseButton.title)\" pauseFits=\(pauseButton.isHidden || pauseButton.intrinsicContentSize.width <= pauseButton.frame.width) pauseTip=\"\(pauseButton.toolTip ?? "")\" status=\"\(statusLabel.stringValue)\" statusTruncated=\(statusLabel.intrinsicContentSize.width > statusLabel.frame.width)")
        if let recordingMenu {
            recordingMenu.update()
            for item in recordingMenu.items {
                print("RECORDING_MENU \(item.title)=\(Self.shortcutText(item)) enabled=\(item.isEnabled) subtitle=\"\(item.subtitle ?? "")\"")
            }
        }
        print("RECORD_ROW pause=\(pauseButton.isHidden ? "hidden" : pauseButton.title) meterGap=\(Int(recordButton.frame.minX - audioMeter.frame.maxX))pt meterEnabled=\(audioMeter.inputAvailable)")
        print("CONFIG_LOCK mode=\(modeControl.isEnabled) screenSource=\(chooseScreenButton.isEnabled) layout=\(screenLayoutControl.isEnabled) frame=\(cameraFrameControl.isEnabled) backdrop=\(canvasBackdropWell.isEnabled) zoom=\(zoomSlider.isEnabled) ratio=\(ratioButtons.first?.isEnabled ?? false) resolution=\(resolutionButtons.first?.isEnabled ?? false) devices=\(captureOptionsButton.isEnabled) format=\(recordingFormatControl.isEnabled)")
        print("TOUCH_UP button=\(touchUpControl.button.isHidden ? "hidden" : "visible") buttonEnabled=\(touchUpControl.button.isEnabled) \(touchUpControl.reportDescription)")
        print("RECORDING_FORMAT selected=\(selectedRecordingFormat.rawValue) detail=\(recordingFormatDetail.stringValue)")
        for menuItem in NSApp.mainMenu?.items ?? [] {
            let shortcuts = (menuItem.submenu?.items ?? [])
                .filter { !$0.keyEquivalent.isEmpty }
                .map { "\($0.title)=\(Self.shortcutText($0))" }
                .joined(separator: " ")
            print("MAIN_MENU \(menuItem.submenu?.title ?? menuItem.title) [\(shortcuts)]")
        }
        for item in makeCaptureOptionsMenu().items {
            let state = item.state == .on ? "✓" : " "
            let kind = item.isSectionHeader ? "section" : (item.isSeparatorItem ? "separator" : "item")
            print("RECORD_MENU \(kind) \(state) \(item.title) enabled=\(item.isEnabled)")
        }
        guard let representation = layoutBitmap(for: contentView) else { return }
        contentView.cacheDisplay(in: contentView.bounds, to: representation)
        if let data = representation.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: outputPath))
        }
    }
}

/// Start/Stop and Pause/Resume read the recorder, wherever they appear — the
/// Recording menu and the menu-bar item alike.
extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let state = reportRecordingState ?? (recorder.isRecording, recorder.isPaused)
        switch menuItem.action {
        case #selector(toggleRecording):
            menuItem.title = state.recording ? "Stop Recording" : "Start Recording"
            return state.recording || recordButton.isEnabled
        case #selector(togglePause):
            menuItem.title = state.paused ? "Resume Recording" : "Pause Recording"
            return state.recording && !qualityCheckRunning
        default:
            return true
        }
    }
}

extension AppDelegate: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        presentedRecording == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        presentedRecording?.url as NSURL?
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Runs the same Recorder as the app, with a bounded capture and explicit
/// artifacts. --legacy-camera reproduces the installed v0.35 input policy.
@MainActor
private enum CameraDiagnosticRunner {
    private static var recorder: Recorder?

    static func run(directory: URL) {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        func begin() {
            do {
                let discovery = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified
                )
                guard let device = discovery.devices.first else {
                    throw NSError(domain: "OneAct.CameraDiagnostic", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "Built-in camera unavailable."
                    ])
                }
                let diagnostics = try CameraFrameDiagnostics(directory: directory)
                let legacy = CommandLine.arguments.contains("--legacy-camera")
                let instance = Recorder(
                    previewLayer: AVCaptureVideoPreviewLayer(), usesNativeCameraFormat: !legacy
                )
                instance.setRecordingFormat(CommandLine.arguments.contains("--prores") ? .proRes422 : .h264)
                recorder = instance
                let portrait = CommandLine.arguments.contains("--portrait")
                instance.setCanvas(CanvasPreset(
                    name: "Diagnostic", width: portrait ? 1440 : 2560, height: portrait ? 2560 : 1440
                ))
                if let zoomIndex = CommandLine.arguments.firstIndex(of: "--zoom"),
                   CommandLine.arguments.indices.contains(zoomIndex + 1),
                   let zoom = Double(CommandLine.arguments[zoomIndex + 1]) {
                    instance.setSoftwareZoom(CGFloat(zoom))
                }
                instance.setMicrophoneIntentionallyDisabled(true)
                instance.setFrameDiagnostics(diagnostics)
                try instance.configure(videoDevice: device, audioDevice: nil)
                instance.startSession { running in
                    guard running else { fail("Capture session did not start.") }
                    // Let exposure and system effects settle before comparing.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        instance.startRecording(to: directory.appendingPathComponent("recording.mov")) { result in
                            if case .failure(let error) = result { fail(error.localizedDescription) }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                                instance.stopRecording { result in
                                    if case .failure(let error) = result { fail(error.localizedDescription) }
                                    diagnostics.finish { result in
                                        switch result {
                                        case .success(let count):
                                            print("CAMERA_DIAGNOSTIC_OK policy=\(legacy ? "legacy" : "native") pairs=\(count) directory=\(directory.path)")
                                            Darwin.exit(0)
                                        case .failure(let error): fail(error.localizedDescription)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } catch { fail(error.localizedDescription) }
        }
        DispatchQueue.main.async {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: begin()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        if granted { begin() } else { fail("Camera access was not granted.") }
                    }
                }
            default: fail("Camera access unavailable; authorize OneAct in System Settings.")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { fail("Diagnostic timed out.") }
        application.run()
    }

    private nonisolated static func fail(_ message: String) -> Never {
        fputs("CAMERA_DIAGNOSTIC_FAILED \(message)\n", stderr)
        Darwin.exit(1)
    }
}

@main
@MainActor
private struct OneActApp {
    static func main() {
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--camera-diagnostic" {
            CameraDiagnosticRunner.run(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--self-test" {
            Darwin.exit(WriterSelfTest.run(
                outputPath: CommandLine.arguments[2],
                format: CommandLine.arguments.contains("--prores") ? .proRes422 : .h264
            ))
        }
        if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--touch-up-bench" {
            Darwin.exit(TouchUpBenchmark.run())
        }
        if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--touch-up-still" {
            Darwin.exit(TouchUpBenchmark.still(inputPath: CommandLine.arguments[2], outputPath: CommandLine.arguments[3]))
        }
        if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--aligner-test" {
            Darwin.exit(ScriptAlignerSelfTest.run())
        }
        if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--speech-report" {
            Darwin.exit(VoiceFollowProbe.speechReport())
        }
        if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--voice-follow-probe" {
            VoiceFollowProbe.run(requestPermission: CommandLine.arguments.contains("--request-permission"))
            RunLoop.main.run()
        }
        if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--save-flow-check" {
            Darwin.exit(SaveFlowCheck.run())
        }
        if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--device-report" {
            Darwin.exit(DeviceReport.run())
        }
        if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--screen-window-test" {
            Darwin.exit(
                ScreenWindowDiagnostic.run(
                    bundleIdentifier: CommandLine.arguments[2],
                    outputPath: CommandLine.arguments[3]
                )
            )
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--layout-report" {
            let outputPath = CommandLine.arguments[2]
            let screenMode = CommandLine.arguments.contains("--screen-mode")
            let minimumSize = CommandLine.arguments.contains("--min-size")
            application.setActivationPolicy(.accessory)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                delegate.writeLayoutReport(
                    outputPath: outputPath,
                    screenMode: screenMode,
                    minimumSize: minimumSize
                )
                Darwin.exit(0)
            }
            application.run()
        }
        application.setActivationPolicy(.regular)
        application.run()
    }
}
