import Foundation
import Combine
import GalleryCore

enum UpdateService {
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }
    static func latest(session: URLSession) async throws -> GalleryRelease {
        var request = URLRequest(url: GalleryRelease.latestAPIURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Gallery", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https",
              http.url?.host?.lowercased() == "api.github.com" else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200: break
        case 403, 429: throw ThemeError.invalid(L("GitHub 暂时限制了请求，请稍后重试。"))
        case 404: throw ThemeError.invalid(L("暂时无法获取正式版本，可前往 GitHub 发行页面查看。"))
        default: throw ThemeError.invalid(L("更新服务暂时不可用，请稍后重试。"))
        }
        let maximum = 2 * 1024 * 1024
        guard response.expectedContentLength <= maximum else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximum else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return try GalleryRelease(data: data)
    }
}

@MainActor final class AppUpdateChecker: ObservableObject {
    static let shared = AppUpdateChecker()
    enum State {
        case idle, checking, current, available(GalleryRelease), failed(String)
    }
    @Published private(set) var state = State.idle
    enum DownloadState { case idle, downloading(Double), verifying, ready(URL), failed(String) }
    @Published private(set) var downloadState = DownloadState.idle
    let currentVersion: String
    private let session: URLSession
    private var task: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var downloadGeneration = UUID()
    private let downloadSession: URLSession?
    init(currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0", session: URLSession = UpdateService.makeSession(), downloadSession: URLSession? = nil) {
        self.currentVersion = currentVersion; self.session = session; self.downloadSession = downloadSession
    }
    deinit { task?.cancel(); downloadTask?.cancel(); session.invalidateAndCancel(); downloadSession?.invalidateAndCancel() }
    var checking: Bool { if case .checking = state { return true }; return false }
    var downloading: Bool {
        switch downloadState { case .downloading, .verifying: return true; default: return false }
    }
    func check() {
        guard !checking, !downloading else { return }
        downloadState = .idle
        state = .checking
        let session = session
        task = Task { [weak self] in
            do {
                let release = try await UpdateService.latest(session: session)
                guard !Task.isCancelled, let self else { return }
                guard let installed = ReleaseVersion(self.currentVersion) else {
                    self.state = .failed(L("无法识别当前版本，请前往发行页面查看。")); return
                }
                self.state = release.version > installed ? .available(release) : .current
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failed((error as? ThemeError)?.localizedDescription ?? L("无法连接更新服务，请检查网络后重试。"))
            }
        }
    }
    func cancel() {
        task?.cancel(); task = nil
        if checking { state = .idle }
    }
    func download(to destination: URL) {
        guard !checking, !downloading, case .available(let release) = state, let package = release.package else { return }
        let generation = UUID(); downloadGeneration = generation
        downloadState = .downloading(0)
        let session = downloadSession
        downloadTask = Task { [weak self] in
            do {
                let file = try await UpdateDownloadService.download(package, to: destination, session: session) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloadGeneration == generation, self.downloading else { return }
                        switch progress {
                        case .transferring(let ratio):
                            if case .downloading(let current) = self.downloadState { self.downloadState = .downloading(max(current, ratio)) }
                        case .verifying: self.downloadState = .verifying
                        }
                    }
                }
                guard !Task.isCancelled, let self, self.downloadGeneration == generation else { return }
                self.downloadState = .ready(file); self.downloadTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.downloadGeneration == generation else { return }
                self.downloadTask = nil
                self.downloadState = .failed((error as? ThemeError)?.localizedDescription ?? L("无法下载安装包，请检查网络后重试。"))
            }
        }
    }
    func cancelDownload() {
        downloadGeneration = UUID(); downloadTask?.cancel(); downloadTask = nil; downloadState = .idle
    }
    func downloadedFile() -> URL? {
        guard case .ready(let file) = downloadState else { return nil }
        guard FileManager.default.fileExists(atPath: file.path) else {
            downloadState = .failed(L("安装包已移动或删除，请重新下载。")); return nil
        }
        return file
    }
}
