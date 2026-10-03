import NativeAgentDomain
import Foundation

#if canImport(WebKit)
import WebKit

@MainActor
enum WebKitExecutor {
    static func execute(
        scriptURL: URL,
        readAccessURL: URL?,
        inputJSON: String,
        policy: WebKitSkillRunnerPolicy
    ) async throws -> String {
        try validateHostSurface()
        let configuration = try await makeConfiguration()
        let box = WebKitNavigationBox()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isHidden = true
        webView.navigationDelegate = box

        return try await withTimeout(
            policy.timeout,
            cancelOperation: { error in
                await box.cancel(in: webView, with: error)
            }
        ) {
            try await box.load(
                scriptURL: scriptURL,
                readAccessURL: readAccessURL,
                into: webView
            )
            let result = try await evaluateResult(in: webView, inputJSON: inputJSON)
            try await box.throwIfPolicyViolated()
            return result
        }
    }

    private static func validateHostSurface() throws {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            throw AgentError.unsupportedSurface(
                "WKWebView skill execution on iOS requires an app-hosted process."
            )
        }
        #endif
    }

    static func makeConfiguration() async throws -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .nonPersistent()
        configuration.limitsNavigationsToAppBoundDomains = true

        let contentController = WKUserContentController()
        contentController.addUserScript(
            WKUserScript(
                source: WebKitPolicyGuardJavaScript.localPureSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        contentController.add(try await WebKitNoNetworkRuleListCache.ruleList())
        configuration.userContentController = contentController
        return configuration
    }

    private static func evaluateResult(
        in webView: WKWebView,
        inputJSON: String
    ) async throws -> String {
        let policyInstalled = try await webView.callAsyncJavaScript(
            "return window.\(WebKitSkillScriptContract.localPurePolicyFlag) === true;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard (policyInstalled as? Bool) == true else {
            throw WebKitSkillRunnerError.policyGuardUnavailable
        }

        let hasEntrypoint = try await webView.callAsyncJavaScript(
            "return typeof window.\(WebKitSkillScriptContract.entrypoint) === 'function';",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard (hasEntrypoint as? Bool) == true else {
            throw WebKitSkillRunnerError.missingFunction
        }

        let result = try await webView.callAsyncJavaScript(
            "return await window.\(WebKitSkillScriptContract.entrypoint)(inputJSON, '');",
            arguments: ["inputJSON": inputJSON],
            in: nil,
            contentWorld: .page
        )
        if let string = result as? String { return string }
        if let json = JSONValue.from(any: result) { return try json.canonicalString() }
        return String(describing: result)
    }

    static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        cancelOperation: @escaping @Sendable (any Error) async -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    let error = WebKitSkillRunnerError.timeout
                    await cancelOperation(error)
                    throw error
                } catch is CancellationError {
                    let error = CancellationError()
                    await cancelOperation(error)
                    throw error
                }
            }
            guard let result = try await group.next() else {
                throw AgentError.unsupportedSurface("WebKit timeout group returned no result.")
            }
            group.cancelAll()
            return result
        }
    }
}
#endif
