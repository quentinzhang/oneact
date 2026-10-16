import AVFoundation
import CoreVideo
import Foundation

/// `--save-flow-check`: walks the path a take takes on disk — default folder
/// created on demand, a movie written into it, a chosen folder kept as a
/// security-scoped bookmark and reopened as if after a relaunch, rename, and
/// Discard & Retake's move to the Trash — with no camera and no clicks.
///
/// Run it from inside the signed bundle (`OneAct.app/Contents/MacOS/OneAct`)
/// so it gets the app's sandbox and entitlements; that is the only setting in
/// which a missing entitlement shows up. The user's own folder choice is left
/// alone: the check keeps its bookmark in a separate preferences suite.
@MainActor
enum SaveFlowCheck {
    private enum CheckError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case .failed(let reason) = self { return reason }
            return nil
        }
    }

    static func run() -> Int32 {
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        let suiteName = "com.oneact.save-flow-check"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return 1 }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stamp = "save-flow-check-\(ProcessInfo.processInfo.processIdentifier)"
        var scratch: [URL] = []
        defer { for url in scratch.reversed() { try? FileManager.default.removeItem(at: url) } }

        do {
            // 1. Default folder, created on demand, writable by the recorder's writer.
            let folder = RecordingsFolder(defaults: defaults)
            guard folder.isDefault else { throw CheckError.failed("fresh suite did not start at the default folder") }
            let first = try folder.nextDestination(timestamp: stamp)
            scratch.append(first.url)
            try writeClip(to: first.url)
            let size = (try first.url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size > 0 else { throw CheckError.failed("written take is empty") }
            let second = try folder.nextDestination(timestamp: stamp)
            guard second.url.lastPathComponent == "OneAct-\(stamp)-2.mov" else {
                throw CheckError.failed("same-second take was named \(second.url.lastPathComponent)")
            }
            guard try posterFrameLoads(first.url) else { throw CheckError.failed("poster frame did not load") }

            // 2. A chosen folder survives a relaunch through its bookmark.
            let chosen = RecordingsFolder.defaultFolder.appendingPathComponent(stamp, isDirectory: true)
            try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
            scratch.insert(chosen, at: 0)
            try folder.choose(chosen)
            let relaunched = RecordingsFolder(defaults: defaults)
            guard !relaunched.isDefault, relaunched.unavailableFolderName == nil,
                  relaunched.current.url.standardizedFileURL.path == chosen.standardizedFileURL.path else {
                throw CheckError.failed("bookmark reopened \(relaunched.current.url.path)")
            }
            let bookmarked = try relaunched.nextDestination(timestamp: stamp)
            try writeClip(to: bookmarked.url)

            // 3. Rename keeps a .mov and refuses names Finder cannot show.
            let renamed = try RecordingsFolder.rename(bookmarked.url, to: "OneAct save-flow check")
            guard renamed.lastPathComponent == "OneAct save-flow check.mov",
                  FileManager.default.fileExists(atPath: renamed.path),
                  !FileManager.default.fileExists(atPath: bookmarked.url.path) else {
                throw CheckError.failed("rename did not move the file")
            }
            let refusedNames = ["a/b", "a:b", ".hidden", "  "].filter { (try? RecordingsFolder.rename(renamed, to: $0)) == nil }
            guard refusedNames.count == 4 else { throw CheckError.failed("invalid names were accepted") }

            // 4. Discard & Retake: to the Trash, never deleted.
            guard let trashed = try RecordingsFolder.moveToTrash(renamed) else {
                throw CheckError.failed("trash reported no destination")
            }
            guard !FileManager.default.fileExists(atPath: renamed.path) else {
                throw CheckError.failed("trashed take is still in place")
            }
            guard try RecordingsFolder.moveToTrash(renamed) == nil else {
                throw CheckError.failed("trashing a missing take did not count as discarded")
            }

            relaunched.resetToDefault()
            print("SAVE_FLOW_OK sandboxed=\(sandboxed) default=\(RecordingsFolder.displayPath(for: RecordingsFolder.defaultFolder)) take_bytes=\(size) collision=\(second.url.lastPathComponent) bookmark=reopened rename=ok refused=\(refusedNames.count) trash=\(trashed.deletingLastPathComponent().lastPathComponent)/\(trashed.lastPathComponent)")
            return 0
        } catch {
            print("SAVE_FLOW_FAILED sandboxed=\(sandboxed) \(error.localizedDescription)")
            return 1
        }
    }

    /// A one-second H.264 movie through AVAssetWriter, the same writer and
    /// container the recorder uses, so any file-access problem surfaces the
    /// way it would mid-take.
    private static func writeClip(to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: VideoEncoding.writerSettings(width: 320, height: 240, format: .h264)
        )
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CheckError.failed("writer did not start") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline, writer.status == .writing else {
                    throw writer.error ?? CheckError.failed("writer stalled")
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw CheckError.failed("pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 8), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else { throw writer.error ?? CheckError.failed("writer did not finish") }
    }

    /// The card's thumbnail reads the take back; in the sandbox that is a
    /// separate permission from writing it.
    private static func posterFrameLoads(_ url: URL) throws -> Bool {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var loaded = false
        generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
            loaded = image != nil
            done.signal()
        }
        return done.wait(timeout: .now() + 10) == .success && loaded
    }
}
