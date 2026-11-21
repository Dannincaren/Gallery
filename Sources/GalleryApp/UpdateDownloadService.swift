import Foundation
import CryptoKit
import GalleryCore

enum UpdateDownloadProgress: Sendable { case transferring(Double), verifying }

/// The initial URL comes from the fixed official release endpoint. HTTPS
/// redirects support GitHub's CDN without credentials or a pinned CDN hostname.
final class UpdateDownloadObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedBytes: Int64
    private let progress: @Sendable (UpdateDownloadProgress) -> Void
    private let lock = NSLock()
    private var lastReport = -Double.infinity
    private var redirects = 0
    private var rejected: String?
    init(expectedBytes: Int64, progress: @escaping @Sendable (UpdateDownloadProgress) -> Void) {
        self.expectedBytes = expectedBytes; self.progress = progress
    }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return rejected }
    static func secure(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com"].contains(host),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return true
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); redirects += 1
        let allowed = redirects <= 8 && Self.secure(request.url)
        if !allowed { rejected = L("更新下载地址无效，请稍后重试。") }
        lock.unlock()
        var redirected = request
        redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        redirected.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(allowed ? redirected : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let tooLarge = totalBytesWritten > expectedBytes || totalBytesExpectedToWrite > GalleryUpdatePackage.maximumBytes
        if tooLarge { rejected = L("安装包大小与更新信息不符，请重新下载。") }
        let now = ProcessInfo.processInfo.systemUptime
        let report = !tooLarge && (now - lastReport >= 0.1 || totalBytesWritten == expectedBytes)
        if report { lastReport = now }
        lock.unlock()
        if tooLarge { downloadTask.cancel() }
        else if report { progress(.transferring(min(1, Double(totalBytesWritten) / Double(expectedBytes)))) }
    }
}

enum UpdateDownloadService {
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }
    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Gallery", forHTTPHeaderField: "User-Agent")
        return request
    }
    static func download(_ package: GalleryUpdatePackage, to destination: URL, session supplied: URLSession? = nil,
                         progress: @escaping @Sendable (UpdateDownloadProgress) -> Void) async throws -> URL {
        guard destination.isFileURL else { throw ThemeError.invalid(L("无法保存安装包，请选择其他位置。")) }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        let session = supplied ?? makeSession()
        defer { if supplied == nil { session.invalidateAndCancel() } }
        let digest: String
        if let known = package.archive.sha256 { digest = known }
        else if let checksums = package.checksums {
            let observer = UpdateDownloadObserver(expectedBytes: checksums.size, progress: { _ in })
            let (file, response) = try await fetch(checksums, session: session, observer: observer)
            defer { try? FileManager.default.removeItem(at: file) }
            try validate(response, file: file, expectedBytes: checksums.size)
            digest = try GalleryUpdatePackage.checksum(in: Data(contentsOf: file))
        } else { throw ThemeError.invalid(L("此版本未提供可验证的安装包，请前往发行页面。")) }
        try Task.checkCancellation()
        let observer = UpdateDownloadObserver(expectedBytes: package.archive.size, progress: progress)
        let (file, response) = try await fetch(package.archive, session: session, observer: observer)
        defer { try? FileManager.default.removeItem(at: file) }
        try validate(response, file: file, expectedBytes: package.archive.size)
        progress(.verifying)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sha = SHA256(), first = true
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            if first {
                guard chunk.starts(with: [0x50, 0x4b, 0x03, 0x04]) else { throw ThemeError.invalid(L("下载的文件不是有效安装包，请重新下载。")) }
                first = false
            }
            sha.update(data: chunk)
        }
        guard !first, sha.finalize().map({ String(format: "%02x", $0) }).joined() == digest else {
            throw ThemeError.invalid(L("安装包校验失败，文件未保存。请重新下载。"))
        }
        try Task.checkCancellation()
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".Gallery-update-" + UUID().uuidString + ".download")
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try FileManager.default.copyItem(at: file, to: staging)
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else { try FileManager.default.moveItem(at: staging, to: destination) }
        } catch is CancellationError { throw CancellationError() }
        catch { throw ThemeError.invalid(L("无法保存安装包，请选择其他位置。")) }
        return destination
    }
    private static func fetch(_ asset: GalleryReleaseAsset, session: URLSession, observer: UpdateDownloadObserver) async throws -> (URL, URLResponse) {
        do {
            let result = try await session.download(for: request(asset.url), delegate: observer)
            if let failure = observer.failure { try? FileManager.default.removeItem(at: result.0); throw ThemeError.invalid(failure) }
            return result
        } catch {
            if let failure = observer.failure { throw ThemeError.invalid(failure) }
            throw error
        }
    }
    private static func validate(_ response: URLResponse, file: URL, expectedBytes: Int64) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, UpdateDownloadObserver.secure(http.url) else {
            throw ThemeError.invalid(L("无法下载安装包，请检查网络后重试。"))
        }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size == expectedBytes, size > 0, size <= GalleryUpdatePackage.maximumBytes else {
            throw ThemeError.invalid(L("安装包大小与更新信息不符，请重新下载。"))
        }
    }
}
