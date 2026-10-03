import Foundation
import NativeAgentDomain

#if canImport(WebKit)
import WebKit

@MainActor
final class WebKitNavigationBox: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var allowedReadRootURL: URL?
    private var policyViolation: WebKitSkillRunnerError?

    func load(
        scriptURL: URL,
        readAccessURL: URL?,
        into webView: WKWebView
    ) async throws {
        let access = try Self.validatedAccess(
            scriptURL: scriptURL,
            readAccessURL: readAccessURL
        )
        allowedReadRootURL = access.root
        policyViolation = nil

        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadFileURL(access.script, allowingReadAccessTo: access.root)
        }
    }

    func cancel(in webView: WKWebView, with error: any Error) {
        webView.stopLoading()
        finish(throwing: error)
    }

    func throwIfPolicyViolated() throws {
        if let policyViolation {
            throw policyViolation
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(returning: ())
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(throwing: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(throwing: error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame != nil else {
            block("new-window", decisionHandler: decisionHandler)
            return
        }
        guard let url = navigationAction.request.url else {
            block("missing-url", decisionHandler: decisionHandler)
            return
        }

        if url.scheme == "about",
           url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc"
        {
            decisionHandler(.allow)
            return
        }

        if url.isFileURL,
           let root = allowedReadRootURL,
           Self.contains(url.resolvingSymlinksInPath().standardizedFileURL, in: root)
        {
            decisionHandler(.allow)
            return
        }

        block(Self.redactedDestination(url), decisionHandler: decisionHandler)
    }

    nonisolated static func validatedAccess(
        scriptURL: URL,
        readAccessURL: URL?
    ) throws -> (script: URL, root: URL) {
        guard scriptURL.isFileURL else {
            throw WebKitSkillRunnerError.fileAccessDenied(
                redactedDestination(scriptURL)
            )
        }

        let script = scriptURL.standardizedFileURL.resolvingSymlinksInPath()
        let requestedRoot = readAccessURL ?? script.deletingLastPathComponent()
        guard requestedRoot.isFileURL else {
            throw WebKitSkillRunnerError.fileAccessDenied(
                redactedDestination(requestedRoot)
            )
        }
        let root = requestedRoot.standardizedFileURL.resolvingSymlinksInPath()

        var scriptIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: script.path,
            isDirectory: &scriptIsDirectory
        ), scriptIsDirectory.boolValue == false else {
            throw WebKitSkillRunnerError.fileAccessDenied(script.lastPathComponent)
        }

        var rootIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: root.path,
            isDirectory: &rootIsDirectory
        ), rootIsDirectory.boolValue else {
            throw WebKitSkillRunnerError.fileAccessDenied(root.lastPathComponent)
        }
        guard contains(script, in: root) else {
            throw WebKitSkillRunnerError.fileAccessDenied(script.lastPathComponent)
        }
        return (script, root)
    }

    nonisolated static func contains(_ candidate: URL, in root: URL) -> Bool {
        candidate.standardizedFileURL.pathComponents.starts(
            with: root.standardizedFileURL.pathComponents
        )
    }

    nonisolated static func redactedDestination(_ url: URL) -> String {
        if url.isFileURL {
            return url.lastPathComponent.ifEmpty("file")
        }
        guard let scheme = url.scheme?.lowercased() else {
            return "unknown"
        }
        if let host = url.host, host.isEmpty == false {
            return "\(scheme)://\(host)"
        }
        return "\(scheme):"
    }

    private func block(
        _ destination: String,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let error = WebKitSkillRunnerError.navigationBlocked(destination)
        policyViolation = error
        decisionHandler(.cancel)
        finish(throwing: error)
    }

    private func finish(returning value: Void) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }

    private func finish(throwing error: any Error) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }
}

#endif
