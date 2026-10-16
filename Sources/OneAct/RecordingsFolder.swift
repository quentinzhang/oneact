import Darwin
import Foundation

/// Where takes are written, decided before Record is pressed so that pressing
/// it starts the take. A save panel in front of every recording put a file
/// browser between "I have something to say" and saying it — and for a
/// one-take recorder, where a flub means a retake, it put one in front of
/// every retake too.
///
/// The default is ~/Movies/OneAct, reachable inside the sandbox through the
/// Movies entitlement. Any other folder is one the user picked in an open
/// panel and is kept as a security-scoped bookmark; access is held for as long
/// as something still needs the folder, which includes a finished take's card
/// after the user has already switched to another folder.
@MainActor
final class RecordingsFolder {
    /// Access to one folder. Releasing the last reference closes a
    /// security-scoped grant; the default folder never opens one.
    final class Access {
        let url: URL
        private let scoped: Bool

        fileprivate init(url: URL, scoped: Bool) {
            self.url = url
            self.scoped = scoped
        }

        deinit {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    /// The next take's file, and the folder access that has to outlive it.
    struct Destination {
        let url: URL
        let folder: Access
    }

    private static let bookmarkKey = "recordings.folderBookmark"
    private let defaults: UserDefaults
    private(set) var current: Access
    /// A chosen folder that could not be opened — on an unplugged drive,
    /// renamed away, or no longer permitted. The take goes to the default
    /// folder instead of failing, and the user is told once. The choice itself
    /// is kept: a drive that is back next launch should just work again.
    private(set) var unavailableFolderName: String?

    /// The real ~/Movies/OneAct. Inside the sandbox `homeDirectoryForCurrentUser`
    /// is the app's container, whose Movies is only a symlink; the user should
    /// see and be taken to the folder they know.
    static var defaultFolder: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } }
            ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent("OneAct", isDirectory: true)
    }

    /// Layout fixtures read and write no preferences; they always see the default.
    init(defaults: UserDefaults = .standard, readsStoredFolder: Bool = true) {
        self.defaults = defaults
        current = Access(url: Self.defaultFolder, scoped: false)
        guard readsStoredFolder, let bookmark = defaults.data(forKey: Self.bookmarkKey) else { return }
        do {
            current = try Self.open(bookmark: bookmark, refreshingIn: defaults)
        } catch {
            unavailableFolderName = Self.storedFolderName(bookmark) ?? "The chosen folder"
        }
    }

    var isDefault: Bool { Self.isDefaultFolder(current.url) }

    /// By path: a folder URL from an open panel may or may not carry a
    /// trailing slash, which URL equality counts as a difference.
    static func isDefaultFolder(_ url: URL) -> Bool {
        url.standardizedFileURL.path == defaultFolder.standardizedFileURL.path
    }

    /// "~/Movies/OneAct" rather than the full path, for menus and the status line.
    var displayPath: String { Self.displayPath(for: current.url) }

    static func displayPath(for url: URL) -> String {
        let home = defaultFolder.deletingLastPathComponent().deletingLastPathComponent().path
        let path = url.path
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Takes the pending notice, so it is shown once rather than on every take.
    func takeUnavailableNotice() -> String? {
        defer { unavailableFolderName = nil }
        return unavailableFolderName
    }

    /// Persists a folder picked in an open panel. The panel's grant only lasts
    /// for this launch; the bookmark is what lets the next launch write there.
    func choose(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let access = try Self.open(bookmark: bookmark, refreshingIn: nil)
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        current = access
        unavailableFolderName = nil
    }

    func resetToDefault() {
        defaults.removeObject(forKey: Self.bookmarkKey)
        current = Access(url: Self.defaultFolder, scoped: false)
        unavailableFolderName = nil
    }

    /// Where the next take goes. A chosen folder that has gone away since it
    /// was picked falls back to the default rather than costing the take.
    func nextDestination(timestamp: String) throws -> Destination {
        do {
            return Destination(url: try Self.nextRecordingURL(in: current.url, timestamp: timestamp), folder: current)
        } catch where !isDefault {
            unavailableFolderName = current.url.lastPathComponent
            let fallback = Access(url: Self.defaultFolder, scoped: false)
            return Destination(url: try Self.nextRecordingURL(in: fallback.url, timestamp: timestamp), folder: fallback)
        }
    }

    /// The folder is created on demand — the default one does not exist until
    /// the first recording, and a user may have deleted it since. Names never
    /// collide: two takes stopped and started within one second would
    /// otherwise ask the writer to reuse an existing file, which it refuses.
    private static func nextRecordingURL(in folder: URL, timestamp: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = "OneAct-\(timestamp)"
        var candidate = folder.appendingPathComponent("\(base).mov")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(suffix).mov")
            suffix += 1
        }
        return candidate
    }

    // MARK: A finished take

    enum TakeFileError: LocalizedError {
        case invalidName(String)
        case nameTaken(String)

        var errorDescription: String? {
            switch self {
            case .invalidName(let name): return "“\(name)” can't be used as a file name"
            case .nameTaken(let name): return "\(name) already exists in that folder"
            }
        }
    }

    /// Renames a take in place, keeping it a .mov. Typing the extension is
    /// optional; "/" and ":" are the same character to Finder, and a leading
    /// dot would hide the take from it. Never replaces another file.
    static func rename(_ url: URL, to proposedName: String) throws -> URL {
        var name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".mov") {
            name = String(name.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else {
            throw TakeFileError.invalidName(proposedName)
        }
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent(name)
            .appendingPathExtension("mov")
        // A change of case only is the same file on a case-insensitive volume.
        let sameFile = destination.path.lowercased() == url.path.lowercased()
        if !sameFile, FileManager.default.fileExists(atPath: destination.path) {
            throw TakeFileError.nameTaken(destination.lastPathComponent)
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// The retake path. The Trash keeps Put Back; there is deliberately no
    /// fallback that deletes, so a take that cannot be trashed stays put.
    /// A take that is already gone counts as discarded.
    @discardableResult
    static func moveToTrash(_ url: URL) throws -> URL? {
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        } catch where !FileManager.default.fileExists(atPath: url.path) {
            return nil
        }
        return trashed as URL?
    }

    private static func open(bookmark: Data, refreshingIn defaults: UserDefaults?) throws -> Access {
        var stale = false
        // Resolved when Record is pressed: an unmounted share must fall back
        // to the default folder at once, not hold the take while it mounts.
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard url.startAccessingSecurityScopedResource() else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        let access = Access(url: url, scoped: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        // A moved or renamed folder still resolves, but through a bookmark
        // that will eventually stop working; re-record it while access is open.
        if stale, let defaults,
           let refreshed = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(refreshed, forKey: bookmarkKey)
        }
        return access
    }

    private static func storedFolderName(_ bookmark: Data) -> String? {
        URL.resourceValues(forKeys: [.nameKey], fromBookmarkData: bookmark)?.name
    }
}
