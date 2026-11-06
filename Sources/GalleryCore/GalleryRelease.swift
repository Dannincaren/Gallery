import Foundation

/// Normalize local four-part versions and published three-part versions onto
/// the same numeric grid: 1.0.1.2 < 1.0.2, and 1.0.2 == 1.0.2.0.
public struct ReleaseVersion: Comparable, Sendable {
    private let components: [Int]
    public init?(_ value: String) {
        let value = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (3...4).contains(parts.count), parts.allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 9 && $0.utf8.allSatisfy { (48...57).contains($0) }
        }) else { return nil }
        components = parts.map { Int($0)! } + Array(repeating: 0, count: 4 - parts.count)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

public struct GalleryRelease: Sendable {
    // Repository IDs survive account and repository renames. The API supplies
    // the canonical release link, which may use a newer owner or project name.
    public static let latestAPIURL = URL(string: "https://api.github.com/repositories/1435228425/releases/latest")!
    public static let releasesURL = URL(string: "https://github.com/Dannincaren/Gallery/releases")!
    public let version: ReleaseVersion
    public let versionName: String
    public let url: URL

    public init(data: Data) throws {
        struct Response: Decodable {
            let tag_name: String
            let html_url: URL
            let draft: Bool
            let prerelease: Bool
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let path = response.html_url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !response.draft, !response.prerelease, let version = ReleaseVersion(response.tag_name),
              response.html_url.scheme == "https", response.html_url.host?.lowercased() == "github.com",
              response.html_url.port == nil, response.html_url.user == nil, response.html_url.password == nil,
              response.html_url.query == nil, response.html_url.fragment == nil,
              path.count == 6, path[0].isEmpty, !path[1].isEmpty, !path[2].isEmpty,
              path[3] == "releases", path[4] == "tag", path[5] == response.tag_name else {
            throw ThemeError.invalid(L("无法识别官方更新信息，请稍后重试。"))
        }
        self.version = version
        versionName = response.tag_name.hasPrefix("v") ? String(response.tag_name.dropFirst()) : response.tag_name
        url = response.html_url
    }
}
