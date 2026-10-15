import CoreGraphics

/// Preserves the requested ratio while avoiding enlargement of the pixels
/// left after aspect-fill cropping and software zoom. H.264 sizes stay even.
enum CameraOutputSizing {
    static func limited(
        width: Int, height: Int,
        sourceWidth: Int, sourceHeight: Int,
        zoom: CGFloat
    ) -> (width: Int, height: Int) {
        guard width > 0, height > 0, sourceWidth > 0, sourceHeight > 0 else {
            return (width, height)
        }
        let usableZoom = Double(SoftwareZoom.clamp(zoom))
        let scale = min(
            1, Double(sourceWidth) / usableZoom / Double(width),
            Double(sourceHeight) / usableZoom / Double(height)
        )
        guard scale < 1 else { return (width, height) }
        // Use even multiples of the reduced ratio, rather than rounding the
        // two axes independently and introducing a tiny stretch or upscale.
        var a = width, b = height
        while b != 0 { (a, b) = (b, a % b) }
        let unitWidth = width / a * 2
        let unitHeight = height / a * 2
        let multiples = max(1, Int((Double(a) * scale / 2).rounded(.down)))
        return (unitWidth * multiples, unitHeight * multiples)
    }
}
