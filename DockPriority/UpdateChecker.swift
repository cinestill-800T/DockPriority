import AppKit
import Foundation

private struct GitHubRelease: Decodable {
    let tag_name: String
    let html_url: String
}

/// Keeps the release page opened by the app within this project's GitHub
/// release routes. The API response is treated as untrusted input.
enum ReleaseURLPolicy {
    static let fallbackURL = URL(string: "https://github.com/cinestill-800T/DockPriority/releases/latest")!

    static func normalizedReleaseURL(rawValue: String) -> URL {
        guard let candidate = URL(string: rawValue), isAllowed(candidate) else {
            return fallbackURL
        }
        return candidate
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return false
        }

        let pathParts = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard pathParts.count >= 5,
              pathParts[0].isEmpty,
              pathParts[1] == "cinestill-800T",
              pathParts[2] == "DockPriority",
              pathParts[3] == "releases" else {
            return false
        }

        if pathParts.count == 5 {
            return pathParts[4] == "latest"
        }
        return pathParts.count == 6 && pathParts[4] == "tag" && !pathParts[5].isEmpty
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var isLoading = false
    @Published var lastChecked: Date?

    private let currentVersion: String
    private let githubURL = "https://api.github.com/repos/cinestill-800T/DockPriority/releases/latest"
    private var task: URLSessionDataTask?

    init() {
        // Get current app version from the same source as the settings display
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            self.currentVersion = version
        } else {
            self.currentVersion = "Unknown"
        }
    }

    func checkForUpdates(isManual: Bool = false) {
        task?.cancel()
        isLoading = true

        guard let url = URL(string: githubURL) else {
            isLoading = false
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLoading = false

                if let error = error {
                    if (error as NSError).code != NSURLErrorCancelled, isManual {
                        self.showErrorNotification(message: "Could not check for updates. Please check your internet connection.")
                    }
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let data else {
                    if isManual {
                        self.showErrorNotification(message: "Could not check for updates. GitHub returned an unexpected response.")
                    }
                    return
                }

                do {
                    let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                    self.processRelease(release, isManual: isManual)
                } catch {
                    if isManual {
                        self.showErrorNotification(message: "Could not check for updates. GitHub returned invalid release data.")
                    }
                }
            }
        }
        task?.resume()
    }

    private func processRelease(_ release: GitHubRelease, isManual: Bool) {
        let latestVersion = release.tag_name.hasPrefix("v")
            ? String(release.tag_name.dropFirst())
            : release.tag_name

        if isNewerVersion(latestVersion) {
            showUpdateNotification(
                latestVersion: latestVersion,
                url: ReleaseURLPolicy.normalizedReleaseURL(rawValue: release.html_url)
            )
        } else if isManual {
            showNoUpdateNotification()
        }

        self.lastChecked = Date()
    }

    private func isNewerVersion(_ latestVersion: String) -> Bool {
        currentVersion.compare(latestVersion, options: .numeric) == .orderedAscending
    }

    private func showUpdateNotification(latestVersion: String, url: URL) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Version \(latestVersion) is available. You are running \(currentVersion)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    private func showNoUpdateNotification() {
        let alert = NSAlert()
        alert.messageText = "No Updates Available"
        alert.informativeText = "You are already running the latest version of DockPriority (\(currentVersion))."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showErrorNotification(message: String) {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
