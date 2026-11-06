import Foundation
import GalleryCore

private final class ReleaseProtocol: URLProtocol {
    static var status = 200
    static var body = Data()
    static var failure: URLError?
    static var hold = false
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if Self.hold { return }
        if let failure = Self.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main @MainActor
struct UpdateHarness {
    static func main() async throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw ThemeError.invalid(message) } }
        if CommandLine.arguments.contains("--live") {
            let session = UpdateService.makeSession(); defer { session.invalidateAndCancel() }
            let release = try await UpdateService.latest(session: session)
            print("PASS anonymous live GitHub release: \(release.versionName) · \(release.url)")
            return
        }
        func session(status: Int = 200, failure: URLError? = nil, hold: Bool = false) -> URLSession {
            ReleaseProtocol.status = status; ReleaseProtocol.failure = failure; ReleaseProtocol.hold = hold
            ReleaseProtocol.requests = []
            ReleaseProtocol.body = Data(#"{"tag_name":"v1.0.2","html_url":"https://github.com/Danningcarer/Gallery/releases/tag/v1.0.2","draft":false,"prerelease":false}"#.utf8)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ReleaseProtocol.self]
            return URLSession(configuration: configuration)
        }
        func finish(_ checker: AppUpdateChecker) async throws {
            for _ in 0..<200 {
                if !checker.checking { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw ThemeError.invalid("Update check did not finish")
        }
        let available = AppUpdateChecker(currentVersion: "1.0.1.2", session: session())
        try check(ReleaseProtocol.requests.isEmpty, "Updater connected before a manual check")
        available.check(); available.check(); available.check()
        try await finish(available)
        guard case .available(let release) = available.state else { throw ThemeError.invalid("New stable release was missed") }
        try check(release.versionName == "1.0.2" && ReleaseProtocol.requests.count == 1, "Version or single-flight behavior changed")
        let request = ReleaseProtocol.requests[0]
        try check(request.url == GalleryRelease.latestAPIURL && request.url?.path == "/repositories/1435228425/releases/latest", "Unexpected update endpoint")
        try check(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil, "Updater sent credentials")
        let current = AppUpdateChecker(currentVersion: "1.0.2", session: session())
        current.check(); try await finish(current)
        guard case .current = current.state else { throw ThemeError.invalid("Equal version was offered as an update") }
        for code in [403, 429, 404, 503] {
            let failed = AppUpdateChecker(currentVersion: "1.0.1", session: session(status: code))
            failed.check(); try await finish(failed)
            guard case .failed(let message) = failed.state, !message.isEmpty else { throw ThemeError.invalid("HTTP failure was presented as up-to-date") }
        }
        let offline = AppUpdateChecker(currentVersion: "1.0.1", session: session(failure: URLError(.notConnectedToInternet)))
        offline.check(); try await finish(offline)
        guard case .failed = offline.state else { throw ThemeError.invalid("Offline failure was lost") }
        let cancelled = AppUpdateChecker(currentVersion: "1.0.1", session: session(hold: true))
        cancelled.check(); try await Task.sleep(nanoseconds: 20_000_000); cancelled.cancel()
        try await Task.sleep(nanoseconds: 20_000_000)
        guard case .idle = cancelled.state else { throw ThemeError.invalid("Cancelled response replaced idle state") }
        print("PASS manual-only updates, trusted endpoint, single flight, new/current versions, HTTP/offline failures and cancellation")
    }
}
