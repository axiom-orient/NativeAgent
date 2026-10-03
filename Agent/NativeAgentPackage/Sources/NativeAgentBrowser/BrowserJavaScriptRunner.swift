import NativeAgentDomain
import Foundation

#if canImport(WebKit)
import WebKit

@MainActor
final class BrowserJavaScriptRunner {
    private var continuation: CheckedContinuation<String, any Error>?
    private var timeoutTimer: Timer?

    func runJSON(
        source: String,
        arguments: [String: any Sendable],
        in webView: WKWebView,
        contentWorld: WKContentWorld,
        maximumResultBytes: Int,
        timeout: Duration
    ) async throws -> JSONValue {
        guard continuation == nil else { throw BrowserError.operationInProgress }
        let wrappedSource = """
        const __nativeAgentValue = await (async () => {
        \(source)
        })();
        const __nativeAgentJSON = JSON.stringify(__nativeAgentValue);
        if (typeof __nativeAgentJSON !== "string") { throw new Error("__NATIVE_AGENT_INVALID_JSON_RESULT__"); }
        if (new TextEncoder().encode(__nativeAgentJSON).byteLength > __nativeAgentMaximumResultBytes) {
            throw new Error("__NATIVE_AGENT_RESULT_TOO_LARGE__");
        }
        return __nativeAgentJSON;
        """
        var webArguments = arguments
        webArguments["__nativeAgentMaximumResultBytes"] = maximumResultBytes
        let encoded = try await evaluate(
            wrappedSource,
            arguments: webArguments,
            in: webView,
            contentWorld: contentWorld,
            timeout: timeout
        )

        guard encoded.utf8.count <= maximumResultBytes,
              let data = encoded.data(using: .utf8) else {
            throw BrowserError.javaScriptResultTooLarge
        }
        do {
            return try JSONDecoder.nativeAgent().decode(JSONValue.self, from: data)
        } catch {
            throw BrowserError.invalidJavaScriptResult
        }
    }

    func cancel() {
        finish(throwing: CancellationError())
    }

    private func evaluate(
        _ source: String,
        arguments: [String: any Sendable],
        in webView: WKWebView,
        contentWorld: WKContentWorld,
        timeout: Duration
    ) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeoutTimer = Timer.scheduledTimer(
                    withTimeInterval: BrowserTiming.timeInterval(timeout),
                    repeats: false
                ) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.finish(throwing: BrowserError.operationTimedOut)
                    }
                }
                webView.callAsyncJavaScript(
                    source,
                    arguments: arguments,
                    in: nil,
                    in: contentWorld
                ) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case let .success(value):
                        guard let encoded = value as? String else {
                            self.finish(throwing: BrowserError.invalidJavaScriptResult)
                            return
                        }
                        self.finish(returning: encoded)
                    case let .failure(error):
                        self.finish(throwing: Self.browserError(from: error))
                    }
                }
            }
        } onCancel: { [weak self] in
            DispatchQueue.main.async {
                self?.cancel()
            }
        }
    }

    private static func browserError(from error: any Error) -> BrowserError {
        let message = error.localizedDescription
        let details = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
        let diagnostic = details ?? message
        if diagnostic.contains("__NATIVE_AGENT_RESULT_TOO_LARGE__") {
            return .javaScriptResultTooLarge
        }
        if diagnostic.contains("__NATIVE_AGENT_HTML_EXPORT_UNAVAILABLE__") {
            return .htmlExportUnavailable
        }
        if diagnostic.contains("__NATIVE_AGENT_STALE_PAGE__") {
            let components = diagnostic.components(separatedBy: "|")
            return .stalePage(
                expected: components.count > 1 ? components[1] : "unknown",
                actual: components.count > 2 ? components[2] : "unknown"
            )
        }
        if diagnostic.contains("__NATIVE_AGENT_ELEMENT_NOT_FOUND__") {
            return .elementNotFound("requested")
        }
        if diagnostic.contains("__NATIVE_AGENT_SENSITIVE_INPUT__") {
            return .sensitiveInputDenied
        }
        if diagnostic.contains("__NATIVE_AGENT_UNSUPPORTED_ELEMENT__") {
            return .unsupportedElement("The requested browser action is not supported for this element.")
        }
        return .navigationFailed(details.map { "\(message): \($0)" } ?? message)
    }

    private func finish(returning value: String) {
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
    }

}
#endif
