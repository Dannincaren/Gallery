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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200: break
        case 403, 429: throw ThemeError.invalid(L("GitHub 暂时限制了请求，请稍后重试。"))
        case 404: throw ThemeError.invalid(L("暂时无法获取正式版本，可前往 GitHub 发行页面查看。"))
        default: throw ThemeError.invalid(L("更新服务暂时不可用，请稍后重试。"))
        }
        guard data.count <= 2 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        return try GalleryRelease(data: data)
    }
}

@MainActor final class AppUpdateChecker: ObservableObject {
    enum State {
        case idle, checking, current, available(GalleryRelease), failed(String)
    }
    @Published private(set) var state = State.idle
    let currentVersion: String
    private let session: URLSession
    private var task: Task<Void, Never>?
    init(currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0", session: URLSession = UpdateService.makeSession()) {
        self.currentVersion = currentVersion; self.session = session
    }
    deinit { task?.cancel(); session.invalidateAndCancel() }
    var checking: Bool { if case .checking = state { return true }; return false }
    func check() {
        guard !checking else { return }
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
}
