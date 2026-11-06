import Foundation
import GalleryCore

final class ReleaseTests {
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
