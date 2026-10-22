import AppKit
import Combine
import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String)
        case downloadOpened(version: String)
        case checkFailed
        case downloadFailed(version: String)
    }

    @Published private(set) var state: State = .idle

    private let currentVersion: String?
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)
    private let openDownload: (URL) -> Bool
    private var downloadURL: URL?

    init(currentVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
         openDownload: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.currentVersion = currentVersion
        self.fetch = fetch
        self.openDownload = openDownload
    }

    func checkForUpdates() async {
        guard state != .checking else { return }
        downloadURL = nil
        state = .checking

        do {
            guard let currentVersion, let installedVersion = Version(currentVersion) else {
                throw CheckError.invalidVersion
            }
            var request = URLRequest(url: URL(string: "https://tidest.app/api/update")!,
                                     cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await fetch(request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw CheckError.invalidResponse
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard let latestVersion = Version(release.version) else { throw CheckError.invalidVersion }
            guard latestVersion > installedVersion else {
                state = .upToDate
                return
            }
            guard let url = URL(string: release.downloadURL),
                  let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
                  let host = url.host, !host.isEmpty else {
                throw CheckError.invalidResponse
            }
            downloadURL = url
            state = .updateAvailable(version: release.version)
        } catch {
            state = .checkFailed
        }
    }

    func downloadUpdate() {
        let version: String
        switch state {
        case .updateAvailable(let availableVersion), .downloadFailed(let availableVersion):
            version = availableVersion
        default:
            return
        }
        guard let downloadURL else { return }
        state = openDownload(downloadURL) ? .downloadOpened(version: version) : .downloadFailed(version: version)
    }

    private struct Release: Decodable {
        let version: String
        let downloadURL: String

        enum CodingKeys: String, CodingKey {
            case version
            case downloadURL = "download_url"
        }
    }

    private enum CheckError: Error {
        case invalidVersion
        case invalidResponse
    }

    private struct Version: Comparable {
        let components: [Int]

        init?(_ value: String) {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty else { return nil }
            var components: [Int] = []
            for part in parts {
                guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                      let number = Int(part) else { return nil }
                components.append(number)
            }
            // Missing trailing components and explicit zeros mean the same version.
            while components.last == 0 { components.removeLast() }
            self.components = components
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            for index in 0..<max(lhs.components.count, rhs.components.count) {
                let left = index < lhs.components.count ? lhs.components[index] : 0
                let right = index < rhs.components.count ? rhs.components[index] : 0
                if left != right { return left < right }
            }
            return false
        }
    }
}
