import NativeAgentDomain
import Foundation

#if canImport(WebKit)
import WebKit

#if canImport(UIKit)
import UIKit
public typealias BrowserPlatformView = UIView
#elseif canImport(AppKit)
import AppKit
public typealias BrowserPlatformView = NSView
#endif

/// A bounded, non-persistent WebKit session for host UI and agent browser tools.
/// Network access is impossible until the caller supplies an explicit policy.
@MainActor
public final class BrowserSession: NSObject {
    public let sessionID: String
    public let policy: BrowserPolicy

    private let navigation: BrowserNavigationDelegate
    private let uiDelegate: BrowserUIDelegate
    private let hostIntegration: BrowserHostIntegration?
    let transientDirectory: URL
    private let scriptRunner = BrowserJavaScriptRunner()
    private let snapshotRunner = BrowserSnapshotRunner()
    private let webView: WKWebView
    private let contentRuleStore = WKContentRuleListStore.default()
    private let contentRuleIdentifier: String
    private var contentPolicyIsPrepared = false
    private var operationIsInProgress = false
    private var sessionIsClosed = false
    private var sessionRequiresReplacement = false
    private var completedDownloads: [BrowserDownload] = []
    private var retainedDownloadBytes: Int64 = 0

    /// `hostIntegration` is the only route that can opt into downloads, file
    /// uploads, popups, media capture, or HTTP authentication. It defaults to
    /// `nil`, which denies all of those capabilities.
    public init(policy: BrowserPolicy, hostIntegration: BrowserHostIntegration? = nil) {
        let transientDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeAgent-Browser-\(UUID().uuidString.lowercased())", isDirectory: true)
        self.sessionID = UUID().uuidString.lowercased()
        self.policy = policy
        self.hostIntegration = hostIntegration
        self.transientDirectory = transientDirectory
        self.contentRuleIdentifier = "NativeAgent.Browser.Policy.v1.\(policy.contentRuleCacheKey)"
        self.navigation = BrowserNavigationDelegate(
            policy: policy,
            maximumResponseBytes: policy.limits.maximumNavigationResponseBytes,
            timeout: policy.limits.navigationTimeout,
            integration: hostIntegration,
            downloadDirectory: transientDirectory.appendingPathComponent("downloads", isDirectory: true),
            canAcceptDownload: { _ in false },
            onDownload: { _ in false }
        )
        self.uiDelegate = BrowserUIDelegate(
            policy: policy,
            integration: hostIntegration,
            uploadDirectory: transientDirectory.appendingPathComponent("uploads", isDirectory: true)
        )

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: BrowserSemanticBridge.source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: BrowserSemanticBridge.contentWorld
            )
        )
        self.webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1_024, height: 768),
            configuration: configuration
        )
        super.init()
        navigation.setDownloadPreflight { [weak self] expectedByteCount in
            self?.canAcceptDownload(expectedByteCount: expectedByteCount) == true
        }
        navigation.setDownloadConsumer { [weak self] download in
            self?.record(download) == true
        }
        webView.navigationDelegate = navigation
        webView.uiDelegate = uiDelegate
    }

    deinit {
        try? FileManager.default.removeItem(at: transientDirectory)
    }

    /// Cancels active WebKit work and removes this session's staged files.
    /// Calling `close()` again is safe and retries cleanup after a prior
    /// filesystem failure.
    public func close() throws {
        if sessionIsClosed == false {
            sessionIsClosed = true
            stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }
        if FileManager.default.fileExists(atPath: transientDirectory.path) {
            try FileManager.default.removeItem(at: transientDirectory)
        }
    }

    /// A host-presentable native view. NativeAgent retains control of its WebKit
    /// delegates; consumers should embed this view without replacing them.
    public var platformView: BrowserPlatformView { webView }

    /// A JavaScript timeout or cancellation leaves WebKit execution state
    /// uncertain. Once this becomes true, do not reuse `platformView`; replace
    /// the session with `makeReplacementSession()` and embed its new view.
    public var requiresReplacement: Bool { sessionRequiresReplacement }

    /// Creates a fresh, non-persistent session with the same host policy and
    /// integration. This deliberately does not transfer page state or view
    /// ownership from an interrupted WebKit process.
    public func makeReplacementSession() -> BrowserSession {
        BrowserSession(policy: policy, hostIntegration: hostIntegration)
    }

    public var currentPage: BrowserPage {
        BrowserPage(
            displayURL: Self.redactedDisplayURL(webView.url),
            title: Self.boundedUTF8(
                webView.title,
                maximumBytes: min(policy.limits.maximumVisibleTextBytes, 4_096)
            ),
            isLoading: webView.isLoading
        )
    }

    /// Returns and clears downloads that were explicitly approved by the host.
    /// Agent tools cannot start a download without the navigation approval that
    /// normally governs `browser.navigate` or `browser.click`.
    public func takeCompletedDownloads() -> [BrowserDownload] {
        defer {
            completedDownloads.removeAll(keepingCapacity: true)
            retainedDownloadBytes = 0
        }
        return completedDownloads
    }

    @discardableResult
    public func navigate(to url: URL) async throws -> BrowserPage {
        try await performExclusive {
            guard policy.allows(url) else {
                throw BrowserError.navigationBlocked(Self.redactedDestination(url))
            }
            try await prepareContentPolicy()
            try await navigation.load(URLRequest(url: url), into: webView)
            return currentPage
        }
    }

    @discardableResult
    public func loadHTML(_ html: String, baseURL: URL? = nil) async throws -> BrowserPage {
        try await performExclusive {
            try await loadHTMLUnlocked(html, baseURL: baseURL)
            return currentPage
        }
    }

    /// Presents generated HTML only when the last observed semantic revision
    /// still matches. Use this rather than `loadHTML` for agent-driven page
    /// replacement so a user's intervening interaction is not overwritten.
    @discardableResult
    public func presentHTML(
        _ html: String,
        baseURL: URL? = nil,
        expectedPageRevision: String
    ) async throws -> BrowserObservation {
        try await performExclusive {
            try await requireExpectedPageRevisionUnlocked(expectedPageRevision)
            try await loadHTMLUnlocked(html, baseURL: baseURL)
            return try await observeUnlocked()
        }
    }

    @discardableResult
    public func goBack() async throws -> BrowserPage {
        try await performExclusive {
            guard webView.canGoBack else { return currentPage }
            try await navigation.loadNavigation(in: webView) { webView.goBack() }
            return currentPage
        }
    }

    @discardableResult
    public func goForward() async throws -> BrowserPage {
        try await performExclusive {
            guard webView.canGoForward else { return currentPage }
            try await navigation.loadNavigation(in: webView) { webView.goForward() }
            return currentPage
        }
    }

    @discardableResult
    public func reload() async throws -> BrowserPage {
        try await performExclusive {
            try await navigation.loadNavigation(in: webView) { webView.reload() }
            return currentPage
        }
    }

    /// Returns a privacy-filtered semantic page observation. Hidden content,
    /// password values, page source, and arbitrary DOM attributes are omitted.
    public func observe() async throws -> BrowserObservation {
        try await performExclusive {
            try await observeUnlocked()
        }
    }

    @discardableResult
    public func click(
        elementID: String,
        expectedPageRevision: String
    ) async throws -> BrowserObservation {
        try await performExclusive {
            _ = try await semanticCall(
                method: "click",
                arguments: [
                    "elementID": elementID,
                    "expectedPageRevision": expectedPageRevision
                ]
            ) as BrowserActionReceipt
            await Task.yield()
            return try await observeUnlocked()
        }
    }

    @discardableResult
    public func type(
        text: String,
        into elementID: String,
        expectedPageRevision: String
    ) async throws -> BrowserObservation {
        try await performExclusive {
            guard text.utf8.count <= policy.limits.maximumActionTextBytes else {
                throw BrowserError.actionTextTooLarge
            }
            _ = try await semanticCall(
                method: "typeText",
                arguments: [
                    "elementID": elementID,
                    "text": text,
                    "expectedPageRevision": expectedPageRevision
                ]
            ) as BrowserActionReceipt
            return try await observeUnlocked()
        }
    }

    @discardableResult
    public func select(
        value: String,
        in elementID: String,
        expectedPageRevision: String
    ) async throws -> BrowserObservation {
        try await performExclusive {
            guard value.utf8.count <= policy.limits.maximumActionTextBytes else {
                throw BrowserError.actionTextTooLarge
            }
            _ = try await semanticCall(
                method: "selectValue",
                arguments: [
                    "elementID": elementID,
                    "value": value,
                    "expectedPageRevision": expectedPageRevision
                ]
            ) as BrowserActionReceipt
            return try await observeUnlocked()
        }
    }

    @discardableResult
    public func scroll(
        deltaX: Int = 0,
        deltaY: Int,
        expectedPageRevision: String
    ) async throws -> BrowserObservation {
        try await performExclusive {
            _ = try await semanticCall(
                method: "scroll",
                arguments: [
                    "deltaX": deltaX,
                    "deltaY": deltaY,
                    "expectedPageRevision": expectedPageRevision
                ]
            ) as BrowserActionReceipt
            return try await observeUnlocked()
        }
    }

    /// Runs host-approved JavaScript in the page world. This API is not
    /// exposed by `BrowserToolPack`; model actions use the semantic bridge.
    public func evaluateJavaScript(_ source: String) async throws -> JSONValue {
        try await performExclusive {
            try await evaluateJavaScriptUnlocked(source, arguments: .object([:]))
        }
    }

    /// Runs bounded page-world JavaScript with JSON arguments exposed as the
    /// `payload` variable. Unlike the host-only convenience overload, this
    /// requires an observed revision and returns the next observation.
    @discardableResult
    public func evaluateJavaScript(
        _ source: String,
        arguments: JSONValue,
        expectedPageRevision: String
    ) async throws -> BrowserJavaScriptEvaluation {
        try await performExclusive {
            try await requireExpectedPageRevisionUnlocked(expectedPageRevision)
            let result = try await evaluateJavaScriptUnlocked(source, arguments: arguments)
            await Task.yield()
            let observation = try await observeUnlocked()
            return BrowserJavaScriptEvaluation(result: result, observation: observation)
        }
    }

    /// Serializes the current rendered DOM into bounded HTML. It is a DOM
    /// export, not a network-response capture; canvas/WebGL pixels require a
    /// visual artifact such as `snapshot()`.
    public func exportRenderedHTML(
        expectedPageRevision: String
    ) async throws -> BrowserHTMLExport {
        try await performExclusive {
            try await requireExpectedPageRevisionUnlocked(expectedPageRevision)
            let serialized = try await scriptRunner.runJSON(
                source: """
                if (!document.documentElement) { throw new Error("__NATIVE_AGENT_HTML_EXPORT_UNAVAILABLE__"); }
                const doctype = document.doctype
                  ? `<!DOCTYPE ${document.doctype.name}${document.doctype.publicId ? ` PUBLIC \"${document.doctype.publicId}\"` : ""}${document.doctype.systemId ? ` \"${document.doctype.systemId}\"` : ""}>\\n`
                  : "";
                return doctype + document.documentElement.outerHTML;
                """,
                arguments: [:],
                in: webView,
                contentWorld: .page,
                maximumResultBytes: policy.limits.maximumHTMLBytes,
                timeout: policy.limits.operationTimeout
            )
            guard case let .string(html) = serialized,
                  html.utf8.count <= policy.limits.maximumHTMLBytes else {
                throw BrowserError.htmlTooLarge
            }
            await Task.yield()
            let observation = try await observeUnlocked()
            guard observation.pageRevision == expectedPageRevision else {
                throw BrowserError.stalePage(
                    expected: expectedPageRevision,
                    actual: observation.pageRevision
                )
            }
            return BrowserHTMLExport(
                sessionID: sessionID,
                html: html,
                pageRevision: observation.pageRevision,
                page: observation.page,
                contentSHA256: SHA256HexDigest.digest(Data(html.utf8))
            )
        }
    }

    public func snapshot(
        preferredFilename: String = "browser.png"
    ) async throws -> ArtifactWriteRequest {
        try await performExclusive {
            let data = try await snapshotRunner.capturePNG(
                in: webView,
                maximumBytes: policy.limits.maximumSnapshotBytes,
                timeout: policy.limits.operationTimeout
            )
            let observation = try await observeUnlocked()
            var metadata: [String: JSONValue] = [
                "pageRevision": .string(observation.pageRevision),
                "contentKind": .string("renderedPixels")
            ]
            if let sourceURL = observation.page.displayURL {
                metadata["sourceURL"] = .string(sourceURL)
            }
            return ArtifactWriteRequest(
                preferredFilename: preferredFilename,
                mimeType: "image/png",
                data: data,
                metadata: metadata
            )
        }
    }

    public func stopLoading() {
        webView.stopLoading()
        navigation.cancel()
        scriptRunner.cancel()
        snapshotRunner.cancel()
    }

    private func canAcceptDownload(expectedByteCount: Int64) -> Bool {
        guard expectedByteCount >= 0,
              expectedByteCount <= policy.limits.maximumDownloadBytes,
              completedDownloads.count < policy.limits.maximumRetainedDownloads,
              retainedDownloadBytes <= policy.limits.maximumRetainedDownloadBytes - expectedByteCount else {
            return false
        }
        return true
    }

    @discardableResult
    private func record(_ download: BrowserDownload) -> Bool {
        let byteCount = Int64(download.artifact.data.count)
        guard canAcceptDownload(expectedByteCount: byteCount) else { return false }
        completedDownloads.append(download)
        retainedDownloadBytes += byteCount
        hostIntegration?.consume(download)
        return true
    }

    private func observeUnlocked() async throws -> BrowserObservation {
        let payload: BrowserBridgeObservation = try await semanticCall(
            method: "observe",
            arguments: [
                "maximumVisibleTextBytes": policy.limits.maximumVisibleTextBytes,
                "maximumElements": policy.limits.maximumObservedElements
            ]
        )
        return BrowserObservation(
            sessionID: sessionID,
            pageRevision: payload.pageRevision,
            page: currentPage,
            visibleText: payload.visibleText,
            elements: payload.elements,
            visibleTextWasTruncated: payload.visibleTextWasTruncated,
            omittedElementCount: payload.omittedElementCount
        )
    }

    private func loadHTMLUnlocked(_ html: String, baseURL: URL?) async throws {
        guard html.utf8.count <= policy.limits.maximumHTMLBytes else {
            throw BrowserError.htmlTooLarge
        }
        if let baseURL, !policy.allows(baseURL) {
            throw BrowserError.navigationBlocked(Self.redactedDestination(baseURL))
        }
        try await prepareContentPolicy()
        try await navigation.loadHTML(html, baseURL: baseURL, into: webView)
    }

    private func requireExpectedPageRevisionUnlocked(_ expected: String) async throws {
        let observation = try await observeUnlocked()
        guard observation.pageRevision == expected else {
            throw BrowserError.stalePage(expected: expected, actual: observation.pageRevision)
        }
    }

    private func evaluateJavaScriptUnlocked(
        _ source: String,
        arguments: JSONValue
    ) async throws -> JSONValue {
        guard source.utf8.count <= policy.limits.maximumJavaScriptSourceBytes else {
            throw BrowserError.javaScriptSourceTooLarge
        }
        guard let object = arguments.objectValue else {
            throw BrowserError.javaScriptArgumentsMustBeObject
        }
        let canonicalArguments: String
        do {
            canonicalArguments = try arguments.canonicalString()
        } catch {
            throw BrowserError.javaScriptArgumentsMustBeObject
        }
        guard canonicalArguments.utf8.count <= policy.limits.maximumJavaScriptArgumentsBytes else {
            throw BrowserError.javaScriptArgumentsTooLarge
        }
        do {
            return try await scriptRunner.runJSON(
                source: source,
                arguments: ["payload": Self.javaScriptArguments(from: object)],
                in: webView,
                contentWorld: .page,
                maximumResultBytes: policy.limits.maximumJavaScriptResultBytes,
                timeout: policy.limits.operationTimeout
            )
        } catch is CancellationError {
            invalidateAfterInterruptedJavaScript()
            throw CancellationError()
        } catch let error as BrowserError where error == .operationTimedOut {
            invalidateAfterInterruptedJavaScript()
            throw error
        }
    }

    private func invalidateAfterInterruptedJavaScript() {
        guard !sessionRequiresReplacement else { return }
        sessionRequiresReplacement = true
        webView.stopLoading()
        navigation.cancel()
        scriptRunner.cancel()
        snapshotRunner.cancel()
    }

    private static func javaScriptArguments(
        from object: [String: JSONValue]
    ) -> [String: any Sendable] {
        object.mapValues(javaScriptArgument)
    }

    private static func javaScriptArgument(_ value: JSONValue) -> any Sendable {
        switch value {
        case let .string(value): value
        case let .integer(value): value
        case let .number(value): value
        case let .bool(value): value
        case let .object(value): javaScriptArguments(from: value)
        case let .array(value): value.map(javaScriptArgument)
        case .null: NSNull()
        }
    }

    private func semanticCall<T: Decodable>(
        method: String,
        arguments: [String: any Sendable]
    ) async throws -> T {
        let source = """
        if (!globalThis.__nativeAgentBrowserBridge) { throw new Error("__NATIVE_AGENT_BRIDGE_UNAVAILABLE__"); }
        return await globalThis.__nativeAgentBrowserBridge[method](payload);
        """
        let value = try await scriptRunner.runJSON(
            source: source,
            arguments: ["method": method, "payload": arguments],
            in: webView,
            contentWorld: BrowserSemanticBridge.contentWorld,
            maximumResultBytes: policy.limits.maximumJavaScriptResultBytes,
            timeout: policy.limits.operationTimeout
        )
        do {
            return try value.decode(T.self)
        } catch {
            throw BrowserError.invalidJavaScriptResult
        }
    }

    private func prepareContentPolicy() async throws {
        guard !contentPolicyIsPrepared else { return }
        guard let contentRuleStore else {
            throw BrowserError.contentPolicyCompilationFailed(
                "WebKit did not provide a content rule list store."
            )
        }
        let encodedContentRuleList: String
        do {
            encodedContentRuleList = try policy.contentRuleJSON
        } catch {
            throw BrowserError.contentPolicyCompilationFailed(error.localizedDescription)
        }
        let ruleList: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            contentRuleStore.compileContentRuleList(
                forIdentifier: contentRuleIdentifier,
                encodedContentRuleList: encodedContentRuleList
            ) { ruleList, error in
                if let ruleList {
                    continuation.resume(returning: ruleList)
                } else {
                    continuation.resume(
                        throwing: BrowserError.contentPolicyCompilationFailed(
                            error?.localizedDescription ?? "WebKit returned no rule list."
                        )
                    )
                }
            }
        }
        webView.configuration.userContentController.add(ruleList)
        contentPolicyIsPrepared = true
    }

    private func performExclusive<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        guard !sessionIsClosed else { throw BrowserError.sessionClosed }
        guard !sessionRequiresReplacement else { throw BrowserError.sessionRequiresReplacement }
        guard !operationIsInProgress else { throw BrowserError.operationInProgress }
        operationIsInProgress = true
        defer { operationIsInProgress = false }
        return try await operation()
    }

    private static func redactedDestination(_ url: URL) -> String {
        redactedDisplayURL(url) ?? url.scheme ?? "unknown"
    }

    private static func redactedDisplayURL(_ url: URL?) -> String? {
        guard let url else { return nil }
        if url.isFileURL { return "file://local-document" }
        if url.absoluteString == "about:blank" { return "about:blank" }
        return (try? BrowserOrigin(url: url))?.description ?? url.scheme
    }

    private static func boundedUTF8(_ value: String?, maximumBytes: Int) -> String? {
        guard let value, value.utf8.count > maximumBytes else { return value }
        var data = Data(value.utf8.prefix(maximumBytes))
        while !data.isEmpty {
            if let result = String(data: data, encoding: .utf8) { return result }
            data.removeLast()
        }
        return ""
    }

}
#endif
