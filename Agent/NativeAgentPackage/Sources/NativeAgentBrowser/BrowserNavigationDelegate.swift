import NativeAgentDomain
import Foundation

#if canImport(WebKit)
import WebKit

private func browserOrigin(for url: URL?) -> BrowserOrigin? {
    url.flatMap { try? BrowserOrigin(url: $0) }
}

@MainActor
final class BrowserNavigationDelegate: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    private struct DownloadContext {
        let sourceOrigin: BrowserOrigin?
        let mimeType: String
        let suggestedFilename: String
        let expectedByteCount: Int64?
        var destination: URL?
    }

    private let policy: BrowserPolicy
    private let maximumResponseBytes: Int64
    private let timeout: Duration
    private let integration: BrowserHostIntegration?
    private let downloadDirectory: URL
    private var canAcceptDownload: @MainActor @Sendable (Int64) -> Bool
    private var onDownload: @MainActor @Sendable (BrowserDownload) -> Bool
    private weak var activeWebView: WKWebView?
    private var activeNavigation: WKNavigation?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var timeoutTimer: Timer?
    private var pendingDownload: DownloadContext?
    private var downloads: [ObjectIdentifier: DownloadContext] = [:]

    init(
        policy: BrowserPolicy,
        maximumResponseBytes: Int64,
        timeout: Duration,
        integration: BrowserHostIntegration?,
        downloadDirectory: URL,
        canAcceptDownload: @escaping @MainActor @Sendable (Int64) -> Bool,
        onDownload: @escaping @MainActor @Sendable (BrowserDownload) -> Bool
    ) {
        self.policy = policy
        self.maximumResponseBytes = maximumResponseBytes
        self.timeout = timeout
        self.integration = integration
        self.downloadDirectory = downloadDirectory
        self.canAcceptDownload = canAcceptDownload
        self.onDownload = onDownload
    }

    func load(_ request: URLRequest, into webView: WKWebView) async throws {
        try await start(in: webView) { webView.load(request) }
    }

    func loadHTML(_ html: String, baseURL: URL?, into webView: WKWebView) async throws {
        try await start(in: webView) { webView.loadHTMLString(html, baseURL: baseURL) }
    }

    func loadNavigation(in webView: WKWebView, start: () -> WKNavigation?) async throws {
        try await self.start(in: webView, navigation: start)
    }

    func cancel() {
        activeWebView?.stopLoading()
        finish(throwing: CancellationError())
    }

    func setDownloadPreflight(_ handler: @escaping @MainActor @Sendable (Int64) -> Bool) {
        canAcceptDownload = handler
    }

    func setDownloadConsumer(_ consumer: @escaping @MainActor @Sendable (BrowserDownload) -> Bool) {
        onDownload = consumer
    }

    private func start(in webView: WKWebView, navigation: () -> WKNavigation?) async throws {
        guard continuation == nil else { throw BrowserError.operationInProgress }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.activeWebView = webView
                guard let activeNavigation = navigation() else {
                    finish(throwing: BrowserError.navigationFailed("WebKit did not create a navigation."))
                    return
                }
                self.activeNavigation = activeNavigation
                timeoutTimer = Timer.scheduledTimer(withTimeInterval: BrowserTiming.timeInterval(timeout), repeats: false) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.activeWebView?.stopLoading()
                        self.finish(throwing: BrowserError.operationTimedOut)
                    }
                }
            }
        } onCancel: {
            DispatchQueue.main.async { self.cancel() }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, policy.allows(url) else {
            decisionHandler(.cancel)
            if navigationAction.targetFrame?.isMainFrame != false {
                finish(throwing: BrowserError.navigationBlocked(Self.redactedDestination(navigationAction.request.url)))
            }
            return
        }
        guard navigationAction.targetFrame == nil else {
            decisionHandler(.allow)
            return
        }

        let request = BrowserPopupRequest(
            sourceOrigin: browserOrigin(for: navigationAction.sourceFrame.request.url),
            destinationOrigin: browserOrigin(for: url)
        )
        guard integration?.popupDecision(for: request) == .openInCurrentSession else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.cancel)
        webView.load(URLRequest(url: url))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        let response = navigationResponse.response
        guard let url = response.url, policy.allows(url) else {
            decisionHandler(.cancel)
            if navigationResponse.isForMainFrame {
                finish(throwing: BrowserError.navigationBlocked(Self.redactedDestination(response.url)))
            }
            return
        }
        let expectedLength = response.expectedContentLength
        guard expectedLength < 0 || expectedLength <= maximumResponseBytes else {
            decisionHandler(.cancel)
            if navigationResponse.isForMainFrame { finish(throwing: BrowserError.navigationBlocked("oversized response")) }
            return
        }
        guard !navigationResponse.canShowMIMEType else {
            decisionHandler(.allow)
            return
        }
        guard navigationResponse.isForMainFrame else {
            decisionHandler(.cancel)
            return
        }
        guard expectedLength < 0 || expectedLength <= policy.limits.maximumDownloadBytes else {
            decisionHandler(.cancel)
            finish(throwing: BrowserError.navigationBlocked("oversized download"))
            return
        }
        guard expectedLength >= 0, canAcceptDownload(expectedLength) else {
            decisionHandler(.cancel)
            finish(throwing: BrowserError.navigationBlocked("download retention limit"))
            return
        }

        let context = DownloadContext(
            sourceOrigin: browserOrigin(for: url),
            mimeType: response.mimeType ?? "application/octet-stream",
            suggestedFilename: response.suggestedFilename ?? "download",
            expectedByteCount: expectedLength >= 0 ? expectedLength : nil,
            destination: nil
        )
        let request = BrowserDownloadRequest(
            sourceOrigin: context.sourceOrigin,
            mimeType: context.mimeType,
            suggestedFilename: context.suggestedFilename,
            expectedByteCount: context.expectedByteCount
        )
        guard integration?.authorizes(request) == true else {
            decisionHandler(.cancel)
            finish(throwing: BrowserError.navigationBlocked("download not approved by host"))
            return
        }
        pendingDownload = context
        decisionHandler(.download)
        finish(returning: ())
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
        if let pendingDownload {
            downloads[ObjectIdentifier(download)] = pendingDownload
            self.pendingDownload = nil
        }
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        let key = ObjectIdentifier(download)
        guard var context = downloads[key] else {
            completionHandler(nil)
            return
        }
        do {
            try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
            let destination = downloadDirectory.appendingPathComponent(Self.safeFilename(suggestedFilename), isDirectory: false)
            context.destination = destination
            downloads[key] = context
            completionHandler(destination)
        } catch {
            downloads.removeValue(forKey: key)
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard let context = downloads.removeValue(forKey: key), let destination = context.destination else { return }
        defer { try? FileManager.default.removeItem(at: destination) }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
              let byteCount = attributes[.size] as? NSNumber,
              byteCount.int64Value <= policy.limits.maximumDownloadBytes,
              let data = try? Data(contentsOf: destination) else { return }
        let metadata: [String: JSONValue] = context.sourceOrigin.map {
            ["sourceOrigin": .string($0.description)]
        } ?? [:]
        _ = onDownload(
            BrowserDownload(
                sourceOrigin: context.sourceOrigin,
                artifact: ArtifactWriteRequest(
                    preferredFilename: Self.safeFilename(context.suggestedFilename),
                    mimeType: context.mimeType,
                    data: data,
                    metadata: metadata
                )
            )
        )
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        let context = downloads.removeValue(forKey: ObjectIdentifier(download))
        if let destination = context?.destination { try? FileManager.default.removeItem(at: destination) }
    }

    func download(
        _ download: WKDownload,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        resolve(challenge, completionHandler: completionHandler)
    }

    func download(
        _ download: WKDownload,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(policy.allows(navigationAction.request.url ?? URL(string: "about:blank")!) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === activeNavigation else { return }
        finish(returning: ())
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        guard navigation === activeNavigation else { return }
        finish(throwing: BrowserError.navigationFailed(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard navigation === activeNavigation else { return }
        finish(throwing: BrowserError.navigationFailed(error.localizedDescription))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(throwing: BrowserError.navigationFailed("WebKit content process terminated."))
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        resolve(challenge, completionHandler: completionHandler)
    }

    func webView(_ webView: WKWebView, authenticationChallenge challenge: URLAuthenticationChallenge, shouldAllowDeprecatedTLS decisionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        decisionHandler(false)
    }

    private func resolve(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let request = BrowserAuthenticationRequest(
            sourceOrigin: Self.origin(for: challenge.protectionSpace.host, protocol: challenge.protectionSpace.protocol, port: challenge.protectionSpace.port),
            method: Self.authenticationMethod(challenge.protectionSpace.authenticationMethod),
            realm: challenge.protectionSpace.realm,
            isProxy: challenge.protectionSpace.isProxy()
        )
        let decision: BrowserAuthenticationDecision
        if request.method == .serverTrust, integration == nil {
            // Standard HTTPS server trust remains WebKit's normal certificate
            // validation path; this is not credential entry.
            decision = .performDefaultHandling
        } else {
            decision = integration?.authenticationDecision(for: request) ?? .cancel
        }
        switch decision {
        case .cancel:
            completionHandler(.cancelAuthenticationChallenge, nil)
        case .performDefaultHandling where request.method == .serverTrust:
            completionHandler(.performDefaultHandling, nil)
        case let .httpCredential(username, password) where request.method == .httpBasic || request.method == .httpDigest:
            completionHandler(.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
        default:
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private func finish(returning value: Void) {
        guard let continuation else { return }
        reset()
        continuation.resume(returning: value)
    }

    private func finish(throwing error: any Error) {
        guard let continuation else { return }
        reset()
        continuation.resume(throwing: error)
    }

    private func reset() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        continuation = nil
        activeNavigation = nil
        activeWebView = nil
    }

    private static func origin(for host: String, protocol scheme: String?, port: Int) -> BrowserOrigin? {
        guard let scheme, let url = URL(string: "\(scheme)://\(host):\(port)") else { return nil }
        return try? BrowserOrigin(url: url)
    }

    private static func authenticationMethod(_ value: String) -> BrowserAuthenticationMethod {
        switch value {
        case NSURLAuthenticationMethodServerTrust: .serverTrust
        case NSURLAuthenticationMethodHTTPBasic: .httpBasic
        case NSURLAuthenticationMethodHTTPDigest: .httpDigest
        case NSURLAuthenticationMethodClientCertificate: .clientCertificate
        case NSURLAuthenticationMethodNTLM: .ntlm
        case NSURLAuthenticationMethodNegotiate: .negotiate
        default: .other
        }
    }

    fileprivate static func safeFilename(_ value: String) -> String {
        let leaf = URL(fileURLWithPath: value).lastPathComponent
        let filtered = leaf.unicodeScalars.map { "/\\:\\0".unicodeScalars.contains($0) ? "_" : Character($0) }
        let result = String(filtered).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "download" : String(result.prefix(180))
    }

    private static func redactedDestination(_ url: URL?) -> String {
        guard let url else { return "missing URL" }
        if url.isFileURL { return "file://local-document" }
        if url.absoluteString == "about:blank" { return "about:blank" }
        return (try? BrowserOrigin(url: url))?.description ?? url.scheme ?? "unknown"
    }

}

@MainActor
final class BrowserUIDelegate: NSObject, WKUIDelegate {
    private let policy: BrowserPolicy
    private let integration: BrowserHostIntegration?
    private let uploadDirectory: URL

    init(policy: BrowserPolicy, integration: BrowserHostIntegration?, uploadDirectory: URL) {
        self.policy = policy
        self.integration = integration
        self.uploadDirectory = uploadDirectory
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        let sourceOrigin = browserOrigin(for: frame.request.url)
        guard let url = frame.request.url, policy.allows(url) else { decisionHandler(.deny); return }
        let request = BrowserMediaCaptureRequest(sourceOrigin: sourceOrigin, kind: Self.mediaKind(type))
        decisionHandler(integration?.authorizes(request) == true ? .grant : .deny)
    }

    /// iOS exposes the file-panel delegate only from 18.4. Earlier iOS
    /// versions therefore have no NativeAgent host-upload opt-in path.
    @available(iOS 18.4, *)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        guard !parameters.allowsDirectories, let url = frame.request.url, policy.allows(url) else { completionHandler(nil); return }
        let request = BrowserUploadRequest(sourceOrigin: browserOrigin(for: url), allowsMultipleSelection: parameters.allowsMultipleSelection, allowsDirectories: parameters.allowsDirectories)
        let uploads = integration?.uploads(for: request) ?? []
        let selected = parameters.allowsMultipleSelection ? uploads : Array(uploads.prefix(1))
        completionHandler(stage(selected))
    }

    #if os(iOS)
    func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
    #endif

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) { completionHandler(nil) }

    private func stage(_ uploads: [BrowserUpload]) -> [URL]? {
        guard !uploads.isEmpty,
              uploads.count <= policy.limits.maximumUploadFiles,
              uploads.reduce(0, { $0 + $1.data.count }) <= policy.limits.maximumUploadBytes else { return nil }
        let batchDirectory = uploadDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: batchDirectory,
                withIntermediateDirectories: true
            )
            return try uploads.enumerated().map { index, upload in
                let filename = BrowserNavigationDelegate.safeFilename(upload.preferredFilename)
                let destination = batchDirectory.appendingPathComponent("\(index)-\(filename)")
                try upload.data.write(to: destination, options: .atomic)
                return destination
            }
        } catch {
            try? FileManager.default.removeItem(at: batchDirectory)
            return nil
        }
    }

    private static func mediaKind(_ type: WKMediaCaptureType) -> BrowserMediaCaptureKind {
        switch type {
        case .camera: .video
        case .microphone: .audio
        case .cameraAndMicrophone: .audioAndVideo
        @unknown default: .audioAndVideo
        }
    }
}
#endif
