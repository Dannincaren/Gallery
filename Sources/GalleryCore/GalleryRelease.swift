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
    public let package: GalleryUpdatePackage?

    public init(data: Data) throws {
        struct Response: Decodable {
            let tag_name: String
            let html_url: URL
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]?
        }
        struct Asset: Decodable {
            let name: String
            let size: Int64?
            let state: String?
            let browser_download_url: String?
            let digest: String?
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
        func asset(_ name: String, limit: Int64) -> GalleryReleaseAsset? {
            let matches = (response.assets ?? []).filter { $0.name == name }
            guard matches.count == 1, let found = matches.first, found.state == "uploaded",
                  let size = found.size, (1...limit).contains(size),
                  let address = found.browser_download_url, let address = URL(string: address),
                  address.scheme == "https", address.host?.lowercased() == "github.com",
                  address.port == nil, address.user == nil, address.password == nil,
                  address.query == nil, address.fragment == nil,
                  address.path == "/\(path[1])/\(path[2])/releases/download/\(response.tag_name)/\(name)" else { return nil }
            let digest = found.digest.flatMap { $0.hasPrefix("sha256:") ? GalleryUpdatePackage.validSHA256(String($0.dropFirst(7))) : nil }
            return GalleryReleaseAsset(url: address, size: size, sha256: digest)
        }
        let archive = asset(GalleryUpdatePackage.archiveName, limit: GalleryUpdatePackage.maximumBytes)
        let checksums = asset("SHA256SUMS.txt", limit: 64 * 1024)
        package = archive.flatMap {
            $0.sha256 != nil || checksums != nil ? GalleryUpdatePackage(archive: $0, checksums: checksums) : nil
        }
    }
}

public struct GalleryReleaseAsset: Sendable {
    public let url: URL
    public let size: Int64
    public let sha256: String?
}

public struct GalleryUpdatePackage: Sendable {
    public static let archiveName = "Gallery-macOS.zip"
    public static let maximumBytes: Int64 = 128 * 1024 * 1024
    public let archive: GalleryReleaseAsset
    public let checksums: GalleryReleaseAsset?
    public static func validSHA256(_ value: String) -> String? {
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return value.lowercased()
    }
    public static func checksum(in data: Data) throws -> String {
        guard data.count <= 64 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw ThemeError.invalid(L("无法读取安装包校验信息。"))
        }
        let matches = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[1] == Substring(archiveName) || fields[1] == Substring("*" + archiveName) else { return nil }
            return String(fields[0])
        }
        guard matches.count == 1, let hash = validSHA256(matches[0]) else { throw ThemeError.invalid(L("无法读取安装包校验信息。")) }
        return hash
    }
}
