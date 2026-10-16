import Foundation

/// The newest Keepers release on GitHub, for the opt-in update check.
public struct ReleaseInfo: Equatable, Sendable {
    public var version: String
    public var page: URL

    public static let latestURL = URL(string: "https://api.github.com/repos/skykery/keepers/releases/latest")!

    /// From GitHub's `releases/latest` response.
    public init?(json: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let page = (object["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        self.page = page
    }

    public init(version: String, page: URL) { self.version = version; self.page = page }

    /// Whether this release is newer than `current` (dotted numbers, e.g. 2.10.0 > 2.9.1).
    public func isNewer(than current: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
