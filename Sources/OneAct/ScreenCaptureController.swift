import CoreMedia
import CoreVideo
import ScreenCaptureKit

struct ScreenStreamDimensions: Equatable {
    let width: Int
    let height: Int
}

enum ScreenStreamGeometry {
    static func outputDimensions(
        contentRect: CGRect,
        pointPixelScale: CGFloat,
        maximumDimension: CGFloat = 3_840
    ) -> ScreenStreamDimensions {
        let sourceWidth = max(contentRect.width, 2) * max(pointPixelScale, 1)
        let sourceHeight = max(contentRect.height, 2) * max(pointPixelScale, 1)
        let uniformScale = min(1, maximumDimension / max(sourceWidth, sourceHeight))

        func evenDimension(_ value: CGFloat) -> Int {
            let rounded = max(2, Int(value.rounded()))
            return rounded.isMultiple(of: 2) ? rounded : rounded - 1
        }

        return ScreenStreamDimensions(
            width: evenDimension(sourceWidth * uniformScale),
            height: evenDimension(sourceHeight * uniformScale)
        )
    }
}

enum ScreenStreamConfigurationFactory {
    static func make(for filter: SCContentFilter) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let dimensions = ScreenStreamGeometry.outputDimensions(
            contentRect: filter.contentRect,
            pointPixelScale: CGFloat(filter.pointPixelScale)
        )

        // Keep the stream surface at exactly the selected content's aspect ratio.
        // Independently clamping width and height creates padding for narrow windows
        // such as iPhone Mirroring, which then gets fitted a second time on the Canvas.
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.destinationRect = CGRect(
            x: 0,
            y: 0,
            width: dimensions.width,
            height: dimensions.height
        )
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(VideoEncoding.frameRate)
        )
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.showMouseClicks = true
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        if filter.style == .window {
            configuration.ignoreShadowsSingleWindow = true
        } else if filter.style == .application {
            configuration.ignoreShadowsDisplay = true
        }
        configuration.captureResolution = .best
        // Keep the alpha ScreenCaptureKit already provides. An opaque stream
        // fills a window's rounded corners with solid white; letting the alpha
        // through means the compositor puts the canvas backdrop (or the blurred
        // background) behind them instead.
        configuration.shouldBeOpaque = false
        configuration.backgroundColor = .clear
        // System audio comes from a Core Audio process tap, not this stream:
        // SCK only delivers audio for display-level shares, and the System
        // Audio toggle must not depend on what happens to be shared.
        configuration.capturesAudio = false
        configuration.streamName = "OneAct Screen"
        return configuration
    }
}

final class ScreenCaptureController: NSObject,
    SCContentSharingPickerObserver,
    SCStreamOutput,
    SCStreamDelegate {

    var onVideoSample: ((CMSampleBuffer) -> Void)?
    var onSelectionChanged: ((Bool, String) -> Void)?
    /// The user finished picking a source, as opposed to cancelling or the
    /// stream ending on its own.
    var onPickerDidSelect: (() -> Void)?
    var onError: ((Error) -> Void)?

    private let outputQueue = DispatchQueue(label: "oneact.screen-capture", qos: .userInteractive)
    private let picker = SCContentSharingPicker.shared
    private var stream: SCStream?
    private var lastPickedStyle: SCShareableContentStyle = .none

    override init() {
        super.init()
        picker.add(self)
        picker.isActive = true
        picker.maximumStreamCount = 1
        // Single-selection modes for the picker panel. The hover overlay the
        // system shows while a stream is already running ignores these modes:
        // it still offers "Add This Window" and merges the picked windows into
        // one display-style filter that renders each window at its desktop
        // position. That native behavior is accepted as-is — the overlay is
        // system UI whose wording cannot be changed, and quietly turning its
        // "add" into a replace was tried and reverted: a button that says Add
        // but swaps reads as a bug. Every path stays picker-authorized, so the
        // app never needs the Screen Recording permission.
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
        configuration.allowsChangingSelectedContent = true
        configuration.excludedBundleIDs = Bundle.main.bundleIdentifier.map { [$0] } ?? []
        picker.configuration = configuration
    }

    deinit {
        picker.remove(self)
    }

    var isReady: Bool { stream != nil }

    func presentPicker() {
        // With a stream running, the picker must be presented *for that
        // stream*. The no-stream variants ask to pick content for a new
        // stream, and with maximumStreamCount = 1 that quota is already spent —
        // so Control Center answers with its "currently sharing" management
        // popover instead of a picker. Only the stream-scoped call goes
        // straight into picking.
        guard let stream else {
            picker.present()
            return
        }
        // Reopen on the kind of content already chosen, so changing one window
        // for another does not start on the display list. The picker's own
        // switcher still reaches everything else.
        picker.present(for: stream, using: lastPickedStyle == .none ? .window : lastPickedStyle)
    }

    func stop() {
        guard let currentStream = stream else { return }
        stream = nil
        currentStream.stopCapture { _ in }
        DispatchQueue.main.async { [weak self] in
            self?.onSelectionChanged?(false, "No screen selected")
        }
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        if self.stream == nil {
            onSelectionChanged?(false, "Screen selection cancelled")
        }
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        lastPickedStyle = filter.style
        // When the picker was presented for our stream — or the system's
        // sharing popover added windows to it — the new filter belongs to that
        // stream, and the sanctioned path is updating it in place. Tearing the
        // stream down to build a new one is how "Add Windows…" came back with
        // a filter for a stream that no longer existed, and nothing changed.
        if let stream, stream === self.stream {
            update(stream, with: filter)
        } else {
            startStream(with: filter)
        }
        // The picker leaves whatever was just shared in front, so without this
        // every source change ends with hunting for the OneAct window — and
        // mid-take, with the clock running, that is the worst moment to go
        // looking for a window. Fires only on an actual selection; cancelling
        // should leave the user where they were.
        DispatchQueue.main.async { [weak self] in
            self?.onPickerDidSelect?()
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        onError?(error)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              sampleBuffer.isValid,
              isCompleteFrame(sampleBuffer),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        onVideoSample?(sampleBuffer)
    }


    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        DispatchQueue.main.async { [weak self] in
            self?.stream = nil
            self?.onSelectionChanged?(false, "Screen capture stopped")
            self?.onError?(error)
        }
    }

    /// Applies new content to the running stream: configuration first, so the
    /// surface is resized for the new content rect (Add Windows grows it to
    /// the union), then the filter itself.
    private func update(_ stream: SCStream, with filter: SCContentFilter) {
        let configuration = makeConfiguration(for: filter)
        stream.updateConfiguration(configuration) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.onError?(error) }
        }
        stream.updateContentFilter(filter) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    // The stream keeps running with its previous content;
                    // saying "no source" here would be wrong on both counts.
                    self.onError?(error)
                } else {
                    let rect = filter.contentRect
                    self.onSelectionChanged?(true, "Selected content · \(Int(rect.width)) × \(Int(rect.height)) pt")
                }
            }
        }
    }

    private func startStream(with filter: SCContentFilter) {
        let startNewStream = { [weak self] in
            guard let self else { return }
            let configuration = self.makeConfiguration(for: filter)
            let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
            do {
                try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.outputQueue)
                try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.outputQueue)
                self.stream = newStream
                newStream.startCapture { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let error {
                            self.stream = nil
                            self.onSelectionChanged?(false, "Unable to start screen capture")
                            self.onError?(error)
                        } else {
                            let rect = filter.contentRect
                            let description = "Selected content · \(Int(rect.width)) × \(Int(rect.height)) pt"
                            self.onSelectionChanged?(true, description)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.stream = nil
                    self?.onSelectionChanged?(false, "Unable to start screen capture")
                    self?.onError?(error)
                }
            }
        }

        if let currentStream = stream {
            stream = nil
            currentStream.stopCapture { _ in startNewStream() }
        } else {
            startNewStream()
        }
    }

    private func makeConfiguration(for filter: SCContentFilter) -> SCStreamConfiguration {
        ScreenStreamConfigurationFactory.make(for: filter)
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentArray.first,
              let rawStatus = attachments[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return true
        }
        return status == .complete
    }
}
