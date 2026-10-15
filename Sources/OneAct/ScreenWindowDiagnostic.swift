import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import ScreenCaptureKit

enum ScreenWindowDiagnostic {
    @MainActor
    static func run(bundleIdentifier: String, outputPath: String) -> Int32 {
        _ = NSApplication.shared
        let semaphore = DispatchSemaphore(value: 0)
        let resultQueue = DispatchQueue(label: "oneact.screen-window-diagnostic.result")
        var result: Int32 = 1

        Task.detached {
            let diagnosticResult: Int32
            do {
                diagnosticResult = try await capture(
                    bundleIdentifier: bundleIdentifier,
                    outputPath: outputPath
                )
            } catch {
                fputs("SCREEN_WINDOW_TEST_FAILED \(error.localizedDescription)\n", stderr)
                diagnosticResult = 1
            }
            resultQueue.sync { result = diagnosticResult }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 30) == .success else {
            fputs("SCREEN_WINDOW_TEST_FAILED timed out waiting for ScreenCaptureKit\n", stderr)
            return 1
        }
        return resultQueue.sync { result }
    }

    private static func capture(
        bundleIdentifier: String,
        outputPath: String
    ) async throws -> Int32 {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let window = content.windows
            .filter({ $0.owningApplication?.bundleIdentifier == bundleIdentifier })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw ScreenWindowDiagnosticError.windowNotFound(bundleIdentifier)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = ScreenStreamConfigurationFactory.make(for: filter)
        let sampleBuffer: CMSampleBuffer = try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureSampleBuffer(
                contentFilter: filter,
                configuration: configuration
            ) { sampleBuffer, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let sampleBuffer {
                    continuation.resume(returning: sampleBuffer)
                } else {
                    continuation.resume(throwing: ScreenWindowDiagnosticError.noSampleBuffer)
                }
            }
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw ScreenWindowDiagnosticError.noPixelBuffer
        }
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw ScreenWindowDiagnosticError.imageConversionFailed
        }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = representation.representation(using: .png, properties: [:]) else {
            throw ScreenWindowDiagnosticError.imageConversionFailed
        }
        try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)

        let sourceRatio = filter.contentRect.width / filter.contentRect.height
        let bufferRatio = CGFloat(bufferWidth) / CGFloat(bufferHeight)
        guard abs(sourceRatio - bufferRatio) < 0.002 else {
            throw ScreenWindowDiagnosticError.aspectRatioMismatch(
                source: sourceRatio,
                output: bufferRatio
            )
        }

        print(
            "SCREEN_WINDOW_TEST_OK bundle=\(bundleIdentifier) "
                + "window_points=\(Int(filter.contentRect.width))x\(Int(filter.contentRect.height)) "
                + "configured=\(configuration.width)x\(configuration.height) "
                + "buffer=\(bufferWidth)x\(bufferHeight) "
                + "path=\(outputPath)"
        )
        return 0
    }
}

private enum ScreenWindowDiagnosticError: LocalizedError {
    case windowNotFound(String)
    case noSampleBuffer
    case noPixelBuffer
    case imageConversionFailed
    case aspectRatioMismatch(source: CGFloat, output: CGFloat)

    var errorDescription: String? {
        switch self {
        case .windowNotFound(let bundleIdentifier):
            "No on-screen window found for \(bundleIdentifier)"
        case .noSampleBuffer:
            "ScreenCaptureKit returned no sample buffer"
        case .noPixelBuffer:
            "ScreenCaptureKit sample had no pixel buffer"
        case .imageConversionFailed:
            "Could not convert the captured window to PNG"
        case .aspectRatioMismatch(let source, let output):
            "Captured surface ratio \(output) did not match source ratio \(source)"
        }
    }
}
