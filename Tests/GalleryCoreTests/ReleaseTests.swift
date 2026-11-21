import Foundation
import GalleryCore

final class ReleaseTests {
    func testDownloadAssetsAndChecksums() throws {
        let digest = String(repeating: "a", count: 64)
        func payload(url: String = "https://github.com/owner/Renamed/releases/download/v1.0.4/Gallery-macOS.zip",
                     size: Int64 = 1024, digest value: String? = "sha256:" + String(repeating: "A", count: 64), checksums: Bool = false, duplicate: Bool = false) throws -> Data {
            var asset: [String: Any] = ["name": "Gallery-macOS.zip", "size": size, "state": "uploaded", "browser_download_url": url]
            if let value { asset["digest"] = value }
            var assets = [asset]
            if duplicate { assets.append(asset) }
            if checksums { assets.append(["name": "SHA256SUMS.txt", "size": 84, "state": "uploaded", "browser_download_url": "https://github.com/owner/Renamed/releases/download/v1.0.4/SHA256SUMS.txt"]) }
            return try JSONSerialization.data(withJSONObject: ["tag_name": "v1.0.4", "html_url": "https://github.com/owner/Renamed/releases/tag/v1.0.4", "draft": false, "prerelease": false, "assets": assets])
        }
        let valid = try require(GalleryRelease(data: payload()).package)
        expectEqual(valid.archive.sha256, digest)
        expectEqual(valid.archive.size, 1024)
        expectNotNil(try GalleryRelease(data: payload(digest: nil, checksums: true)).package)
        expectEqual(try GalleryRelease(data: payload(digest: nil)).package == nil, true)
        expectEqual(try GalleryRelease(data: payload(duplicate: true)).package == nil, true)
        for size: Int64 in [0, -1, GalleryUpdatePackage.maximumBytes + 1] {
            expectEqual(try GalleryRelease(data: payload(size: size)).package == nil, true)
        }
        for address in ["http://github.com/owner/Renamed/releases/download/v1.0.4/Gallery-macOS.zip",
                        "https://example.com/Gallery-macOS.zip", "https://github.com/other/Renamed/releases/download/v1.0.4/Gallery-macOS.zip",
                        "https://github.com/owner/Renamed/releases/download/v1.0.3/Gallery-macOS.zip",
                        "https://github.com/owner/Renamed/releases/download/v1.0.4/Gallery-macOS.zip?other=1"] {
            expectEqual(try GalleryRelease(data: payload(url: address)).package == nil, true)
        }
        expectEqual(try GalleryUpdatePackage.checksum(in: Data((digest + "  Gallery-macOS.zip\n").utf8)), digest)
        expectEqual(try GalleryUpdatePackage.checksum(in: Data((digest.uppercased() + " *Gallery-macOS.zip\r\n").utf8)), digest)
        for invalid in [digest + " other.zip", "bad Gallery-macOS.zip", digest + " Gallery-macOS.zip\n" + digest + " Gallery-macOS.zip", digest + " Gallery-macOS.zip\nbad Gallery-macOS.zip"] {
            expectThrows(try GalleryUpdatePackage.checksum(in: Data(invalid.utf8)))
        }
    }
    func testStableReleaseAndLocalVersionComparison() throws {
        expectGreater(ReleaseVersion("1.0.2")!, ReleaseVersion("1.0.1.25")!)
        expectGreater(ReleaseVersion("v1.0.10")!, ReleaseVersion("1.0.9")!)
        expectEqual(ReleaseVersion("1.0.2"), ReleaseVersion("1.0.2.0"))
        for invalid in ["1.0", "1..2", "1.0.2-beta.1", "1.0.2+test", "1.0.2.3.4", "1.-1.2", "1.0.２", "1.0.99999999999"] {
            expectEqual(ReleaseVersion(invalid), nil)
        }
        func payload(tag: String = "v1.0.2", url: String = "https://github.com/Danningcarer/Gallery/releases/tag/v1.0.2", draft: Bool = false, prerelease: Bool = false) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["tag_name": tag, "html_url": url, "draft": draft, "prerelease": prerelease])
        }
        let release = try GalleryRelease(data: payload())
        expectEqual(release.versionName, "1.0.2")
        expectEqual(release.version, ReleaseVersion("1.0.2"))
        expectEqual(release.url.host, "github.com")
        let renamed = try GalleryRelease(data: payload(url: "https://github.com/Dannincaren/Gallery/releases/tag/v1.0.2"))
        expectEqual(renamed.version, release.version)
        expectThrows(try GalleryRelease(data: payload(draft: true)))
        expectThrows(try GalleryRelease(data: payload(prerelease: true)))
        expectThrows(try GalleryRelease(data: payload(tag: "v1.0.2-beta")))
        for url in ["https://example.com/file.zip", "http://github.com/Danningcarer/Gallery/releases/tag/v1.0.2", "https://github.com/Danningcarer/Gallery/tree/v1.0.2", "https://github.com/Danningcarer/Gallery/releases/tag/v1.0.1", "https://github.com/Danningcarer/Gallery/releases/tag/v1.0.2?next=other"] {
            expectThrows(try GalleryRelease(data: payload(url: url)))
        }
        expectThrows(try GalleryRelease(data: Data("{}".utf8)))
    }
}
