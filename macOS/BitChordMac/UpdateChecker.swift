import AppKit
import Combine
import Foundation

struct ReleaseVersion: Comparable {
    let core: [Int]
    let prerelease: [String]

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        value = String(value.split(separator: "+", maxSplits: 1).first ?? "")
        let pieces = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard !numbers.isEmpty,
              numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        core = numbers.compactMap { Int($0) }
        guard core.count == numbers.count else { return nil }
        prerelease = pieces.count == 2
            ? pieces[1].split(separator: ".").map(String.init)
            : []
    }

    static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        compareCore(lhs.core, rhs.core) == 0 && lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let coreResult = compareCore(lhs.core, rhs.core)
        if coreResult != 0 { return coreResult < 0 }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        for index in 0..<max(lhs.prerelease.count, rhs.prerelease.count) {
            guard index < lhs.prerelease.count else { return true }
            guard index < rhs.prerelease.count else { return false }
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left == right { continue }
            if let leftNumber = Int(left), let rightNumber = Int(right) {
                return leftNumber < rightNumber
            }
            if Int(left) != nil { return true }
            if Int(right) != nil { return false }
            return left.localizedStandardCompare(right) == .orderedAscending
        }
        return false
    }

    private static func compareCore(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let pageURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case pageURL = "html_url"
    }
}

private enum UpdateCheckError: LocalizedError {
    case invalidResponse
    case invalidVersion(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "GitHub returned an unexpected response. Please try again later."
        case let .invalidVersion(version):
            "The latest release has an unsupported version tag: \(version)."
        }
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var isChecking = false

    private let latestReleaseURL = URL(string: "https://api.github.com/repos/aplinxy9plin/lilt/releases/latest")!
    private let lastCheckKey = "Lilt.lastSuccessfulUpdateCheck"
    private let automaticCheckInterval: TimeInterval = 6 * 60 * 60

    func checkAutomatically() async {
        if let lastCheck = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(lastCheck) < automaticCheckInterval {
            return
        }
        await check(manual: false)
    }

    func checkManually() async {
        await check(manual: true)
    }

    private func check(manual: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            let release = try await fetchLatestRelease()
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            let currentString = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            guard let current = ReleaseVersion(currentString) else {
                throw UpdateCheckError.invalidVersion(currentString)
            }
            guard let latest = ReleaseVersion(release.tagName) else {
                throw UpdateCheckError.invalidVersion(release.tagName)
            }

            if current < latest {
                showUpdateAvailable(current: currentString, latest: release.tagName, pageURL: release.pageURL)
            } else if manual {
                showUpToDate(version: currentString)
            }
        } catch {
            if manual { showFailure(error) }
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Lilt-macOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateCheckError.invalidResponse
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func showUpdateAvailable(current: String, latest: String, pageURL: URL) {
        let displayVersion = latest.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApplication.shared.applicationIconImage
        alert.messageText = "A new version of Lilt is available"
        alert.informativeText = "Lilt \(displayVersion) is available. You currently have version \(current)."
        alert.addButton(withTitle: "Open Release")
        alert.addButton(withTitle: "Later")
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(pageURL)
        }
    }

    private func showUpToDate(version: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApplication.shared.applicationIconImage
        alert.messageText = "Lilt is up to date"
        alert.informativeText = "You are running the latest version (\(version))."
        alert.addButton(withTitle: "OK")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to check for updates"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
