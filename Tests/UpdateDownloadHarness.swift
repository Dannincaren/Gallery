import Foundation
import CryptoKit
import GalleryCore

private final class TransferProtocol: URLProtocol {
    struct Fixture { let metadata: Data, archive: Data, checksums: Data; let hold: Bool, status: Int }
    private static let lock = NSLock()
    private static var fixture: Fixture!
    private static var seen: [URLRequest] = []
    static func configure(_ value: Fixture) { lock.lock(); fixture = value; seen = []; lock.unlock() }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let value = Self.fixture!; Self.seen.append(request); Self.lock.unlock()
        let path = request.url!.path, metadata = path.hasSuffix("/latest"), checksum = path.hasSuffix(".txt")
        let body = metadata ? value.metadata : (checksum ? value.checksums : value.archive)
        let response = HTTPURLResponse(url: request.url!, statusCode: metadata ? 200 : value.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(body.count), "Content-Type": metadata ? "application/json" : "application/octet-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if value.hold && !metadata { return }
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

extension UpdateHarness {
    @MainActor static func checkDownloads() async throws {
        func check(_ result: Bool, _ reason: String) throws { if !result { throw ThemeError.invalid(reason) } }
        let archive = Data(base64Encoded: "UEsDBBQAAAAAANl8cF3KX4x1HQAAAB0AAAAKAAAAUkVBRE1FLnR4dEdhbGxlcnkgdXBkYXRlciB0ZXN0IGZpeHR1cmUKUEsBAhQDFAAAAAAA2XxwXcpfjHUdAAAAHQAAAAoAAAAAAAAAAAAAAIABAAAAAFJFQURNRS50eHRQSwUGAAAAAAEAAQA4AAAARQAAAAAA")!
        let sha = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Gallery-update-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func fixture(digest: String? = sha, checksums: Bool = false, size: Int? = nil, hold: Bool = false, status: Int = 200, body: Data? = nil) throws -> AppUpdateChecker {
            let checksum = Data((sha + "  Gallery-macOS.zip\n").utf8)
            let base = "https://github.com/owner/Gallery/releases/download/v9.0.0/"
            var asset: [String: Any] = ["name": "Gallery-macOS.zip", "size": size ?? archive.count, "state": "uploaded", "browser_download_url": base + "Gallery-macOS.zip"]
            if let digest { asset["digest"] = "sha256:" + digest }
            var assets = [asset]
            if checksums { assets.append(["name": "SHA256SUMS.txt", "size": checksum.count, "state": "uploaded", "browser_download_url": base + "SHA256SUMS.txt"]) }
            let metadata = try JSONSerialization.data(withJSONObject: ["tag_name": "v9.0.0", "html_url": "https://github.com/owner/Gallery/releases/tag/v9.0.0", "draft": false, "prerelease": false, "assets": assets])
            TransferProtocol.configure(.init(metadata: metadata, archive: body ?? archive, checksums: checksum, hold: hold, status: status))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [TransferProtocol.self]; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
            let session = URLSession(configuration: configuration)
            return AppUpdateChecker(currentVersion: "1.0.3", session: session, downloadSession: session)
        }
        func finish(_ checker: AppUpdateChecker) async throws {
            for _ in 0..<300 {
                if !checker.checking && !checker.downloading { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw ThemeError.invalid("Update transfer did not finish")
        }
        func ready(_ checker: AppUpdateChecker, _ destination: URL) async throws {
            checker.check(); try await finish(checker)
            checker.download(to: destination); checker.download(to: destination); checker.check()
            try await finish(checker)
        }
        let destination = root.appendingPathComponent("Gallery.zip")
        let good = try fixture()
        try check(TransferProtocol.requests.isEmpty, "Downloader connected before a manual action")
        try await ready(good, destination)
        guard case .ready(let saved) = good.downloadState else { throw ThemeError.invalid("Verified package was not saved: \(String(describing: good.downloadState))") }
        try check(saved == destination && (try Data(contentsOf: destination)) == archive, "Saved package differs")
        try check(TransferProtocol.requests.count == 2, "Duplicate checks/downloads were not coalesced")
        try check(TransferProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && $0.value(forHTTPHeaderField: "Cookie") == nil }, "Downloader sent credentials")
        print("PASS manual in-app download, exact bytes, single flight and no credentials")

        let original = Data("previous download".utf8)
        try original.write(to: destination)
        let badDigest = try fixture(digest: String(repeating: "0", count: 64))
        try await ready(badDigest, destination)
        guard case .failed = badDigest.downloadState else { throw ThemeError.invalid("Mismatched checksum was accepted") }
        try check(try Data(contentsOf: destination) == original, "Failed checksum overwrote an existing download")
        let badSize = try fixture(size: archive.count + 1)
        try await ready(badSize, destination)
        guard case .failed = badSize.downloadState else { throw ThemeError.invalid("Truncated package was accepted") }
        try check(try Data(contentsOf: destination) == original, "Failed size check overwrote an existing download")
        let server = try fixture(status: 503)
        try await ready(server, destination)
        guard case .failed = server.downloadState else { throw ThemeError.invalid("HTTP failure was accepted") }
        let html = Data("An error page, not a package".utf8)
        let htmlSHA = SHA256.hash(data: html).map { String(format: "%02x", $0) }.joined()
        let invalid = try fixture(digest: htmlSHA, size: html.count, body: html)
        try await ready(invalid, destination)
        guard case .failed = invalid.downloadState else { throw ThemeError.invalid("Non-ZIP content was accepted") }
        try check(try Data(contentsOf: destination) == original, "Invalid content overwrote an existing download")
        print("PASS checksum/size/HTTP failures preserve existing files")

        let fallback = try fixture(digest: nil, checksums: true)
        try await ready(fallback, destination)
        guard case .ready = fallback.downloadState else { throw ThemeError.invalid("Checksum-file fallback failed") }
        try check(try Data(contentsOf: destination) == archive, "Verified replacement is incorrect")
        try check(TransferProtocol.requests.count == 3, "Legacy checksum path did not request both assets")
        print("PASS legacy checksum-file fallback and verified atomic replacement")

        try FileManager.default.removeItem(at: destination)
        try check(fallback.downloadedFile() == nil, "Removed package was still offered for opening")
        guard case .failed = fallback.downloadState else { throw ThemeError.invalid("Removed package did not offer a retry") }
        let cancel = try fixture(hold: true)
        cancel.check(); try await finish(cancel); cancel.download(to: destination)
        try await Task.sleep(nanoseconds: 30_000_000)
        try check(cancel.downloading, "Held transfer did not start")
        cancel.cancel()
        try check(cancel.downloading, "Closing the settings section cancelled its download")
        cancel.cancelDownload(); try await Task.sleep(nanoseconds: 30_000_000)
        guard case .idle = cancel.downloadState else { throw ThemeError.invalid("Cancelled transfer changed state later") }
        try check(!FileManager.default.fileExists(atPath: destination.path), "Cancelled download left a partial destination")
        try check(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty, "Transfer left staging files")
        print("PASS cancellation leaves no partial destination or staging file")

        let counter = ProgressCounter(), observer = UpdateDownloadObserver(expectedBytes: 1000, progress: { _ in counter.increment() })
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://github.com/file")!)
        for n in 1...1000 { observer.urlSession(session, downloadTask: task, didWriteData: 1, totalBytesWritten: Int64(n), totalBytesExpectedToWrite: 1000) }
        try check(counter.value <= 3, "Progress delivery is not throttled")
        var redirect = URLRequest(url: URL(string: "https://release-assets.githubusercontent.com/file?token=test")!)
        redirect.setValue("test", forHTTPHeaderField: "Authorization"); redirect.setValue("test", forHTTPHeaderField: "Cookie")
        let response = HTTPURLResponse(url: URL(string: "https://github.com/file")!, statusCode: 302, httpVersion: nil, headerFields: [:])!
        var forwarded: URLRequest?
        observer.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirect) { forwarded = $0 }
        try check(forwarded != nil && forwarded?.value(forHTTPHeaderField: "Authorization") == nil && forwarded?.value(forHTTPHeaderField: "Cookie") == nil, "CDN redirect retained credentials")
        redirect.url = URL(string: "http://example.com/file")
        observer.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirect) { forwarded = $0 }
        try check(forwarded == nil && observer.failure != nil, "Insecure redirect was accepted")
        for address in ["https://127.0.0.1/file", "https://localhost/file", "https://example.com/file",
                        "https://release-assets.githubusercontent.com.evil.test/file", "https://github.com:8443/file",
                        "https://user:pass@github.com/file"] {
            try check(!UpdateDownloadObserver.secure(URL(string: address)), "Untrusted redirect accepted: \(address)")
        }
        print("PASS bounded progress and credential-free HTTPS redirects restricted to GitHub asset hosts")
    }
}
