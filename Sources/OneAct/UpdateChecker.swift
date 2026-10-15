import AppKit

/// Checks the official website's appcast for a newer release and offers the
/// download page. Deliberately not Sparkle: this app ships as a signed .app
/// inside a zip with no installer, so "open the download in the browser" is
/// the whole upgrade story and a JSON file on the website is enough feed.
@MainActor
final class UpdateChecker {
    /// Shape of appcast.json on the website.
    private struct Appcast: Decodable {
        let version: String
        let download: URL
        let notes: String?
    }

    private static let defaultFeed = "https://quentinzhang.github.io/oneact/appcast.json"
    private static let lastCheckKey = "updateLastCheckAt"
    private static let skippedVersionKey = "updateSkippedVersion"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Nil when running the bare development binary (`swift run` has no
    /// Info.plist), which also disables checking — a dev build's version is
    /// meaningless against the appcast.
    private var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private var feedURL: URL? {
        let string = Bundle.main.object(forInfoDictionaryKey: "OneActUpdateFeedURL") as? String
        return URL(string: string ?? Self.defaultFeed)
    }

    /// Launch-time check: at most once per day, and only ever speaks up when
    /// there is a new, non-skipped version. Failures stay silent — a launch
    /// without network must not produce an error dialog.
    func checkAutomatically() {
        guard currentVersion != nil else { return }
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.checkInterval else { return }
        defaults.set(Date(), forKey: Self.lastCheckKey)

        Task {
            guard let appcast = try? await fetchAppcast() else { return }
            guard let current = currentVersion,
                  Self.isVersion(appcast.version, newerThan: current),
                  appcast.version != defaults.string(forKey: Self.skippedVersionKey)
            else { return }
            presentUpdateAlert(for: appcast)
        }
    }

    /// Menu-triggered check: always answers, including "up to date" and
    /// network errors, and ignores a previously skipped version.
    func checkManually() {
        guard let current = currentVersion else {
            presentInfoAlert(
                title: "Development Build",
                text: "This binary is running outside an app bundle, so it has no version to compare. Package the app first."
            )
            return
        }
        Task {
            do {
                let appcast = try await fetchAppcast()
                if Self.isVersion(appcast.version, newerThan: current) {
                    presentUpdateAlert(for: appcast)
                } else {
                    presentInfoAlert(
                        title: "You're Up to Date",
                        text: "OneAct \(current) is the latest version."
                    )
                }
            } catch {
                presentInfoAlert(
                    title: "Update Check Failed",
                    text: "Could not reach the update server. \(error.localizedDescription)"
                )
            }
        }
    }

    private func fetchAppcast() async throws -> Appcast {
        guard let url = feedURL else { throw URLError(.badURL) }
        // Ignore caches: a CDN-stale appcast that hides a release for a day is
        // worse than the extra bytes.
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Appcast.self, from: data)
    }

    /// Numeric dot-component comparison; missing components count as 0, so
    /// "0.36" > "0.35.2" is decided by 36 vs 35, and "1.0" == "1.0.0".
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func presentUpdateAlert(for appcast: Appcast) {
        let alert = NSAlert()
        alert.messageText = "OneAct \(appcast.version) Is Available"
        var text = "You have \(currentVersion ?? "an unknown version")."
        if let notes = appcast.notes, !notes.isEmpty {
            text += "\n\n\(notes)"
        }
        alert.informativeText = text
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Remind Me Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(appcast.download)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(appcast.version, forKey: Self.skippedVersionKey)
        default:
            break
        }
    }

    private func presentInfoAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
