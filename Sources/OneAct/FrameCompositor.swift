import CoreGraphics
import CoreImage
import CoreVideo

enum SoftwareZoom {
    /// 1× is already the widest framing this crop can produce: aspect-fill uses
    /// the full sensor image on one axis, so anything below 1× would only shrink
    /// the picture and pad the canvas rather than reveal more of the scene.
    static let minimum: CGFloat = 1
    static let maximum: CGFloat = 3

    static func clamp(_ zoom: CGFloat) -> CGFloat {
        max(minimum, min(zoom, maximum))
    }
}

enum CameraOverlayScale {
    /// Scales the camera overlay box itself. Zoom changes how much of the camera
    /// frame is shown inside that box; this changes how big the box is.
    static let minimum: CGFloat = 0.6
    static let framedMaximum: CGFloat = 1.6
    /// A cutout has no box to fill, so zoom and size would both do nothing but
    /// scale the person. Zoom is hidden for that style and this one slider
    /// covers the range the two of them used to cover together.
    static let cutoutMaximum: CGFloat = 3

    static func range(for style: CameraFrameStyle) -> ClosedRange<CGFloat> {
        minimum...(style == .cutout ? cutoutMaximum : framedMaximum)
    }

    static func clamp(_ scale: CGFloat, for style: CameraFrameStyle) -> CGFloat {
        let limits = range(for: style)
        return max(limits.lowerBound, min(scale, limits.upperBound))
    }

    /// Clamped to the widest range any style allows, so a value set for a cutout
    /// survives a trip through a framed style instead of being cut down to 1.6×
    /// and lost. Each style narrows it further where it is used.
    static func clamp(_ scale: CGFloat) -> CGFloat {
        max(minimum, min(scale, cutoutMaximum))
    }
}

enum CaptureMode: Int {
    case cameraOnly
    case screenAndCamera
}

enum ScreenLayoutMode: Int, CaseIterable {
    case fit
    case fill
    case blur

    var label: String {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill"
        case .blur: "Blur Background"
        }
    }
}

enum ScreenVerticalAlignment: Int, CaseIterable {
    case top
    case center
    case bottom

    var label: String {
        switch self {
        case .top: "Top"
        case .center: "Center"
        case .bottom: "Bottom"
        }
    }
}

enum PictureInPicturePosition: Int, CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var label: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }
}

enum CameraFrameStyle: Int, CaseIterable {
    case rectangle
    case circle
    case cutout
    case hidden

    var label: String {
        switch self {
        case .rectangle: "Rectangle"
        case .circle: "Circle"
        case .cutout: "Cutout"
        case .hidden: "Hidden"
        }
    }

    var symbolName: String {
        switch self {
        case .rectangle: "rectangle"
        case .circle: "circle"
        case .cutout: "person.and.background.striped.horizontal"
        case .hidden: "person.slash"
        }
    }

    var detail: String {
        switch self {
        case .rectangle: "Rounded rectangle with a white border"
        case .circle: "Circle with a white border"
        case .cutout: "Transparent background · the person is cut out and placed whole, never clipped by a frame"
        case .hidden: "Screen only · the camera is not composited"
        }
    }

    /// Cutout needs a per-frame person mask; the framed styles do not.
    var needsPersonMask: Bool { self == .cutout }

    var showsCamera: Bool { self != .hidden }

    /// Zoom decides how much of the camera frame fits inside a visible frame.
    /// A cutout has no frame, so zoom and size would both do nothing but scale
    /// the person: only size is offered.
    var usesSoftwareZoom: Bool { self != .cutout }
}

/// Where a cutout's camera frame and the person inside it land on the canvas.
struct CutoutPlacement {
    /// Applied to the camera frame to bring it to canvas scale.
    var scale: CGFloat
    /// The whole camera frame, uncropped — most of it is transparent.
    var cameraRect: CGRect
    /// The person inside it. This is what the layout aims, and the only part
    /// of a cutout there is to grab when dragging.
    var personRect: CGRect
}

/// Smooths the person's box over time. Segmentation wobbles by a pixel or two
/// every frame, and a placement that tracked it exactly would make the person
/// twitch: a deadband drops jitter outright and whatever is left is eased in,
/// so the framing follows a moving person like a slow camera operator.
struct PersonBoxTracker {
    /// Normalized to the camera frame, lower-left origin.
    private(set) var box: CGRect?

    private let easing: CGFloat = 0.08
    private let deadband: CGFloat = 0.006

    /// A nil measurement means the mask was lost this frame, not that the
    /// person left: the last known box is held rather than dropped.
    mutating func update(with measurement: CGRect?) {
        guard let measurement else { return }
        guard let current = box else {
            box = measurement
            return
        }
        box = CGRect(
            x: eased(current.minX, toward: measurement.minX),
            y: eased(current.minY, toward: measurement.minY),
            width: eased(current.width, toward: measurement.width),
            height: eased(current.height, toward: measurement.height)
        )
    }

    mutating func reset() {
        box = nil
    }

    private func eased(_ current: CGFloat, toward target: CGFloat) -> CGFloat {
        abs(target - current) < deadband ? current : current + (target - current) * easing
    }
}

enum FrameCompositor {
    /// Magnified image pixels use Lanczos. Clamp the sampling footprint at
    /// the image edge and restore the exact extent, including cropped sources.
    private static func scaled(_ image: CIImage, x: CGFloat, y: CGFloat) -> CIImage {
        let transform = CGAffineTransform(scaleX: x, y: y)
        guard max(x, y) > 1.000001 else { return image.transformed(by: transform) }
        return image.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: y,
            kCIInputAspectRatioKey: x / y
        ]).cropped(to: image.extent.applying(transform))
    }

    static func aspectFill(
        _ source: CIImage,
        width: Int,
        height: Int,
        zoom: CGFloat = 1,
        verticalAlignment: ScreenVerticalAlignment = .center,
        cropOffset: CGPoint = .zero
    ) -> CIImage {
        let sourceExtent = source.extent
        let targetAspect = CGFloat(width) / CGFloat(height)
        let sourceAspect = sourceExtent.width / sourceExtent.height

        let baseCropRect: CGRect
        if sourceAspect > targetAspect {
            let cropWidth = sourceExtent.height * targetAspect
            baseCropRect = CGRect(
                x: sourceExtent.minX + (sourceExtent.width - cropWidth) / 2,
                y: sourceExtent.minY,
                width: cropWidth,
                height: sourceExtent.height
            )
        } else {
            let cropHeight = sourceExtent.width / targetAspect
            let cropY: CGFloat
            switch verticalAlignment {
            case .top:
                cropY = sourceExtent.maxY - cropHeight
            case .center:
                cropY = sourceExtent.minY + (sourceExtent.height - cropHeight) / 2
            case .bottom:
                cropY = sourceExtent.minY
            }
            baseCropRect = CGRect(
                x: sourceExtent.minX,
                y: cropY,
                width: sourceExtent.width,
                height: cropHeight
            )
        }

        // The crop can slide inside whatever slack the source leaves; ±0.5 puts
        // it flush against an edge. This is what dragging the screen adjusts.
        let slackX = sourceExtent.width - baseCropRect.width
        let slackY = sourceExtent.height - baseCropRect.height
        let offsetCropRect = CGRect(
            x: min(
                max(baseCropRect.minX + slackX * cropOffset.x, sourceExtent.minX),
                sourceExtent.maxX - baseCropRect.width
            ),
            y: min(
                max(baseCropRect.minY + slackY * cropOffset.y, sourceExtent.minY),
                sourceExtent.maxY - baseCropRect.height
            ),
            width: baseCropRect.width,
            height: baseCropRect.height
        )

        let clampedZoom = SoftwareZoom.clamp(zoom)
        let cropRect = CGRect(
            x: offsetCropRect.midX - (offsetCropRect.width / clampedZoom) / 2,
            y: offsetCropRect.midY - (offsetCropRect.height / clampedZoom) / 2,
            width: offsetCropRect.width / clampedZoom,
            height: offsetCropRect.height / clampedZoom
        )
        let normalized = source
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
        return scaled(normalized, x: CGFloat(width) / cropRect.width, y: CGFloat(height) / cropRect.height)
    }

    static func aspectFit(
        _ source: CIImage,
        width: Int,
        height: Int,
        backgroundColor: CIColor = .black
    ) -> CIImage {
        let sourceExtent = source.extent
        let normalized = source.transformed(
            by: CGAffineTransform(translationX: -sourceExtent.minX, y: -sourceExtent.minY)
        )
        let scale = min(
            CGFloat(width) / sourceExtent.width,
            CGFloat(height) / sourceExtent.height
        )
        let resized = scaled(normalized, x: scale, y: scale)
        let x = (CGFloat(width) - resized.extent.width) / 2
        let y = (CGFloat(height) - resized.extent.height) / 2
        let positioned = resized.transformed(by: CGAffineTransform(translationX: x, y: y))
        let canvasRect = CGRect(x: 0, y: 0, width: width, height: height)
        let background = CIImage(color: backgroundColor).cropped(to: canvasRect)
        return positioned.composited(over: background).cropped(to: canvasRect)
    }

    static func screenWithCamera(
        screen: CIImage,
        camera: CIImage?,
        width: Int,
        height: Int,
        cameraZoom: CGFloat,
        position: PictureInPicturePosition,
        screenLayout: ScreenLayoutMode = .fit,
        verticalAlignment: ScreenVerticalAlignment = .center,
        cameraFrame: CameraFrameStyle = .rectangle,
        cameraOrigin: CGPoint? = nil,
        cameraScale: CGFloat = 1,
        screenCropOffset: CGPoint = .zero,
        canvasBackground: CIColor = .black,
        personBox: CGRect? = nil
    ) -> CIImage {
        let canvas = screenCanvas(
            screen,
            width: width,
            height: height,
            layout: screenLayout,
            verticalAlignment: verticalAlignment,
            cropOffset: screenCropOffset,
            background: canvasBackground
        )
        guard let camera, cameraFrame.showsCamera else { return canvas }

        let canvasWidth = CGFloat(width)
        let canvasHeight = CGFloat(height)
        let canvasRect = CGRect(x: 0, y: 0, width: width, height: height)
        let border = max(4, floor(min(canvasWidth, canvasHeight) * 0.004))
        let pipFrame = cameraOverlayFrame(
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            style: cameraFrame,
            position: position,
            origin: cameraOrigin,
            scale: cameraScale
        )

        // A cutout is placed rather than framed: the camera image keeps its full
        // width and only the canvas edge may crop it. Zoom is deliberately not
        // applied — with no frame to fill it would only duplicate the size
        // control, and it is hidden from the interface for this style.
        if cameraFrame == .cutout {
            let placement = cutoutPlacement(
                cameraExtent: camera.extent,
                personBox: personBox,
                region: pipFrame,
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight
            )
            return place(camera, at: placement)
                .composited(over: canvas)
                .cropped(to: canvasRect)
        }

        let pip = cameraOverlay(
            camera: camera,
            size: pipFrame.size,
            zoom: cameraZoom,
            style: cameraFrame,
            border: border
        )
        return pip
            .transformed(by: CGAffineTransform(translationX: pipFrame.minX, y: pipFrame.minY))
            .composited(over: canvas)
            .cropped(to: canvasRect)
    }

    /// Where a cutout lands. The camera frame is never cropped to a box: a
    /// cutout carries its own alpha, so a rectangle around it is invisible and
    /// can do nothing but slice the person — which is exactly the artefact this
    /// placement removes. The frame is scaled by the target region's height and
    /// then slid until the person inside it lines up with that region: centred
    /// on it horizontally, standing on its lower edge.
    static func cutoutPlacement(
        cameraExtent: CGRect,
        personBox: CGRect?,
        region: CGRect,
        canvasWidth: CGFloat,
        canvasHeight: CGFloat
    ) -> CutoutPlacement {
        guard cameraExtent.width > 0, cameraExtent.height > 0, region.height > 0 else {
            return CutoutPlacement(scale: 1, cameraRect: region, personRect: region)
        }

        // Matching the height the old aspect-fill crop produced keeps the person
        // exactly the size they were before, at every size-slider position.
        let scale = region.height / cameraExtent.height
        let frame = CGRect(
            x: 0,
            y: 0,
            width: cameraExtent.width * scale,
            height: cameraExtent.height * scale
        )

        // Without a mask the whole frame is the anchor, which reproduces the old
        // placement: camera centred on the region, sitting on its lower edge.
        let anchor: CGRect
        if let personBox, personBox.width > 0, personBox.height > 0 {
            anchor = CGRect(
                x: personBox.minX * frame.width,
                y: personBox.minY * frame.height,
                width: personBox.width * frame.width,
                height: personBox.height * frame.height
            )
        } else {
            anchor = frame
        }

        var offsetX = region.midX - anchor.midX
        // The canvas edge is the only thing left that can crop a person, and it
        // is kept off three of them. The lower edge is not clamped: a body
        // running off the bottom is how a cutout is meant to sit, and it is the
        // camera that cropped it there, not this layout.
        if anchor.width <= canvasWidth {
            let left = anchor.minX + offsetX
            if left < 0 { offsetX -= left }
            let right = anchor.maxX + offsetX
            if right > canvasWidth { offsetX -= right - canvasWidth }
        }

        var offsetY = region.minY - anchor.minY
        let top = anchor.maxY + offsetY
        if top > canvasHeight { offsetY -= top - canvasHeight }

        return CutoutPlacement(
            scale: scale,
            cameraRect: frame.offsetBy(dx: offsetX, dy: offsetY),
            personRect: anchor.offsetBy(dx: offsetX, dy: offsetY)
        )
    }

    private static func place(_ camera: CIImage, at placement: CutoutPlacement) -> CIImage {
        let extent = camera.extent
        let normalized = camera
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        return scaled(normalized, x: placement.scale, y: placement.scale)
            .transformed(by: CGAffineTransform(
                translationX: placement.cameraRect.minX,
                y: placement.cameraRect.minY
            ))
    }

    /// Mirrors an image about its own vertical centre line, leaving its extent
    /// where it was. Only needed when the capture connection refuses to mirror
    /// for us — some virtual cameras do — because a flip applied here has to be
    /// applied to the person's box as well to keep the two in step.
    static func mirroredHorizontally(_ image: CIImage) -> CIImage {
        let extent = image.extent
        return image
            .transformed(by: CGAffineTransform(translationX: -extent.midX, y: 0))
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            .transformed(by: CGAffineTransform(translationX: extent.midX, y: 0))
    }

    /// The same flip for a box normalized to that image.
    static func mirroredHorizontally(_ box: CGRect) -> CGRect {
        CGRect(x: 1 - box.maxX, y: box.minY, width: box.width, height: box.height)
    }

    /// The person's bounding box inside a segmentation mask, normalized to the
    /// mask with a lower-left origin. A row or column has to carry a minimum
    /// number of lit pixels to count, so the speckle segmentation leaves around
    /// the edges cannot stretch the box out to the frame border.
    static func personBox(in mask: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var columnCounts = [Int](repeating: 0, count: width)
        var rowCounts = [Int](repeating: 0, count: height)
        for row in 0..<height {
            let rowStart = row * bytesPerRow
            var lit = 0
            for column in 0..<width where bytes[rowStart + column] > 128 {
                columnCounts[column] += 1
                lit += 1
            }
            rowCounts[row] = lit
        }

        let columnFloor = max(1, height / 50)
        let rowFloor = max(1, width / 50)
        guard let firstColumn = columnCounts.firstIndex(where: { $0 >= columnFloor }),
              let lastColumn = columnCounts.lastIndex(where: { $0 >= columnFloor }),
              let firstRow = rowCounts.firstIndex(where: { $0 >= rowFloor }),
              let lastRow = rowCounts.lastIndex(where: { $0 >= rowFloor }) else { return nil }

        // Mask rows run top-down; Core Image counts y up from the bottom.
        return CGRect(
            x: CGFloat(firstColumn) / CGFloat(width),
            y: CGFloat(height - lastRow - 1) / CGFloat(height),
            width: CGFloat(lastColumn - firstColumn + 1) / CGFloat(width),
            height: CGFloat(lastRow - firstRow + 1) / CGFloat(height)
        )
    }

    /// Where the camera overlay lands on the canvas. `origin` is a dragged
    /// position in canvas pixels; without one the overlay snaps to `position`.
    static func cameraOverlayFrame(
        canvasWidth: CGFloat,
        canvasHeight: CGFloat,
        style: CameraFrameStyle,
        position: PictureInPicturePosition,
        origin: CGPoint? = nil,
        scale: CGFloat = 1
    ) -> CGRect {
        let size = cameraOverlaySize(
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            style: style,
            scale: scale
        )
        guard size.width > 0, size.height > 0 else { return .zero }

        let margin = max(24, floor(min(canvasWidth, canvasHeight) * 0.035))
        // A cutout has no frame to separate it from the canvas edge, so the
        // region it is aimed at sits flush against the edge it is anchored to
        // and the person stands on that edge rather than hovering above it.
        let verticalMargin: CGFloat = style == .cutout ? 0 : margin

        let anchored: CGPoint
        switch position {
        case .topLeft:
            anchored = CGPoint(x: margin, y: canvasHeight - verticalMargin - size.height)
        case .topRight:
            anchored = CGPoint(
                x: canvasWidth - margin - size.width,
                y: canvasHeight - verticalMargin - size.height
            )
        case .bottomLeft:
            anchored = CGPoint(x: margin, y: verticalMargin)
        case .bottomRight:
            anchored = CGPoint(x: canvasWidth - margin - size.width, y: verticalMargin)
        }

        let requested = origin ?? anchored
        return CGRect(
            x: min(max(requested.x, 0), max(0, canvasWidth - size.width)),
            y: min(max(requested.y, 0), max(0, canvasHeight - size.height)),
            width: size.width,
            height: size.height
        )
    }

    static func cameraOverlaySize(
        canvasWidth: CGFloat,
        canvasHeight: CGFloat,
        style: CameraFrameStyle,
        scale: CGFloat = 1
    ) -> CGSize {
        let base = baseCameraOverlaySize(
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            style: style
        )
        guard base.width > 0 else { return .zero }
        let clampedScale = CameraOverlayScale.clamp(scale, for: style)
        return CGSize(
            width: floor(base.width * clampedScale),
            height: floor(base.height * clampedScale)
        )
    }

    private static func baseCameraOverlaySize(
        canvasWidth: CGFloat,
        canvasHeight: CGFloat,
        style: CameraFrameStyle
    ) -> CGSize {
        switch style {
        case .rectangle:
            let pipFraction: CGFloat = canvasWidth < canvasHeight ? 0.42 : 0.28
            let pipWidth = max(240, floor(canvasWidth * pipFraction))
            return CGSize(width: pipWidth, height: floor(pipWidth * 9 / 16))
        case .cutout:
            // Same height as the circle, so the person is rendered at the same
            // scale in every style; the 3:4 region only adds head room.
            let cutoutHeight = max(240, floor(min(canvasWidth, canvasHeight) * 0.3))
            return CGSize(width: floor(cutoutHeight * 3 / 4), height: cutoutHeight)
        case .hidden:
            return .zero
        case .circle:
            // A circle keeps roughly the area of the rectangle instead of its
            // width, so switching styles does not change the visual weight much.
            let diameter = max(240, floor(min(canvasWidth, canvasHeight) * 0.3))
            return CGSize(width: diameter, height: diameter)
        }
    }

    /// Framed styles only — a cutout is placed by `cutoutPlacement` instead,
    /// precisely because it has no frame to be cropped into.
    private static func cameraOverlay(
        camera: CIImage,
        size: CGSize,
        zoom: CGFloat,
        style: CameraFrameStyle,
        border: CGFloat
    ) -> CIImage {
        let outerRect = CGRect(origin: .zero, size: size)
        let innerRect = outerRect.insetBy(dx: border, dy: border)
        let positionedCamera = aspectFill(
            camera,
            width: Int(innerRect.width),
            height: Int(innerRect.height),
            zoom: zoom
        ).transformed(
            by: CGAffineTransform(translationX: innerRect.minX, y: innerRect.minY)
        )

        let cornerFraction: CGFloat = style == .circle ? 0.5 : 0.08
        let transparent = CIImage(color: .clear).cropped(to: outerRect)
        let maskedCamera = positionedCamera.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: transparent,
                kCIInputMaskImageKey: roundedMask(
                    extent: innerRect,
                    radius: min(innerRect.width, innerRect.height) * cornerFraction
                )
            ]
        )
        let borderImage = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.92))
            .cropped(to: outerRect)
            .applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: transparent,
                    kCIInputMaskImageKey: roundedMask(
                        extent: outerRect,
                        radius: min(size.width, size.height) * cornerFraction
                    )
                ]
            )
        return maskedCamera.composited(over: borderImage)
    }

    static func screenCanvas(
        _ source: CIImage,
        width: Int,
        height: Int,
        layout: ScreenLayoutMode,
        verticalAlignment: ScreenVerticalAlignment,
        cropOffset: CGPoint = .zero,
        background: CIColor = .black
    ) -> CIImage {
        // The screen frame carries alpha now — a window's rounded corners arrive
        // transparent — so every layout flattens onto the backdrop before the
        // camera overlay goes on top. A canvas left partly transparent would
        // expose whatever the recycled pixel buffer still held.
        let canvasRect = CGRect(x: 0, y: 0, width: width, height: height)
        let backdrop = CIImage(color: background).cropped(to: canvasRect)

        switch layout {
        case .fit:
            return aspectFit(source, width: width, height: height, backgroundColor: background)
        case .fill:
            return aspectFill(
                source,
                width: width,
                height: height,
                verticalAlignment: verticalAlignment,
                cropOffset: cropOffset
            )
                .composited(over: backdrop)
                .cropped(to: canvasRect)
        case .blur:
            let filled = aspectFill(source, width: width, height: height)
            let radius = max(18, CGFloat(max(width, height)) * 0.022)
            let blurred = filled
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: canvasRect)
            let dim = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.24))
                .cropped(to: canvasRect)
            let softBackground = dim.composited(over: blurred).composited(over: backdrop)
            return aspectFit(
                source,
                width: width,
                height: height,
                backgroundColor: .clear
            )
                .composited(over: softBackground)
                .cropped(to: canvasRect)
        }
    }

    /// Applies a Vision person-segmentation mask to a camera frame, leaving the
    /// background fully transparent. The mask is usually smaller than the camera
    /// frame, so it is scaled onto the camera extent first.
    static func personCutout(camera: CIImage, mask: CIImage) -> CIImage {
        let cameraExtent = camera.extent
        let maskExtent = mask.extent
        guard maskExtent.width > 0, maskExtent.height > 0 else { return camera }

        let scaledMask = mask
            .transformed(by: CGAffineTransform(translationX: -maskExtent.minX, y: -maskExtent.minY))
            .transformed(by: CGAffineTransform(
                scaleX: cameraExtent.width / maskExtent.width,
                y: cameraExtent.height / maskExtent.height
            ))
            .transformed(by: CGAffineTransform(translationX: cameraExtent.minX, y: cameraExtent.minY))

        // Vision returns a one-component mask, so the value lives in the red
        // channel; CIBlendWithMask would read alpha instead and keep everything.
        return camera.applyingFilter(
            "CIBlendWithRedMask",
            parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: cameraExtent),
                kCIInputMaskImageKey: scaledMask
            ]
        ).cropped(to: cameraExtent)
    }

    private static func roundedMask(extent: CGRect, radius: CGFloat) -> CIImage {
        guard let filter = CIFilter(name: "CIRoundedRectangleGenerator") else {
            return CIImage(color: .white).cropped(to: extent)
        }
        filter.setValue(CIVector(cgRect: extent), forKey: "inputExtent")
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(CIColor.white, forKey: "inputColor")
        return filter.outputImage?.cropped(to: extent)
            ?? CIImage(color: .white).cropped(to: extent)
    }
}
