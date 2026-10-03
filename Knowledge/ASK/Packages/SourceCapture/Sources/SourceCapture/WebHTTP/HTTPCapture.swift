import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KnowledgeCore

public enum WebHTTPCollector {
    public static let defaultUserAgent = "ask-webcollect/1.0 (+https://example.invalid/ask-webcollect)"

    public static func fetchURL(
        _ urlString: String,
        timeout: TimeInterval = 20,
        maxAttempts: Int = 3,
        userAgent: String = defaultUserAgent,
        session: URLSession = .shared,
        policy: WebFetchPolicy = .default
    ) async throws -> FetchedResponse {
        let request = try makeWebRequest(
            urlString: urlString,
            timeout: timeout,
            userAgent: userAgent,
            policy: policy
        )

        let attempts = max(1, maxAttempts)
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                let (data, response) = try await performWebDataRequest(
                    session: session,
                    request: request,
                    policy: policy
                )
                return try decodeFetchedResponse(
                    data: data,
                    response: response,
                    originalURL: urlString
                )
            } catch let error as RetryableWebFetchError {
                lastError = error.diagnostic
                if attempt == attempts { break }
            } catch {
                if error is CancellationError {
                    throw error
                }
                if let urlError = error as? URLError, urlError.code == .cancelled {
                    throw CancellationError()
                }
                lastError = error
                guard attempt < attempts, shouldRetryTransportError(error) else {
                    throw error
                }
            }
        }
        throw lastError ?? ASKError.validation("failed to fetch `\(urlString)`")
    }

    public static func captureURL(
        _ urlString: String,
        sourceID: String,
        observedAt: String,
        rawRelpath: String,
        connector: String = "official-web-http",
        capturedAt: String? = nil,
        tags: [String] = [],
        metadata: ASKFields = [:],
        timeout: TimeInterval = 20,
        maxAttempts: Int = 3,
        userAgent: String = defaultUserAgent,
        session: URLSession = .shared,
        policy: WebFetchPolicy = .default
    ) async throws -> WebCaptureBundle {
        let fetched = try await fetchURL(
            urlString,
            timeout: timeout,
            maxAttempts: maxAttempts,
            userAgent: userAgent,
            session: session,
            policy: policy
        )
        return try WebCapture.captureHTMLData(
            Data(fetched.html.utf8),
            url: fetched.originalURL,
            finalURL: fetched.finalURL,
            contentType: fetched.contentType,
            statusCode: fetched.statusCode,
            sourceID: sourceID,
            observedAt: observedAt,
            capturedAt: capturedAt ?? observedAt,
            rawRelpath: rawRelpath,
            connector: connector,
            tags: tags,
            metadata: metadata,
            sourceKind: .url,
            transport: "http"
        )
    }
}

private func shouldRetryTransportError(_ error: Error) -> Bool {
    guard let urlError = error as? URLError else { return false }
    return switch urlError.code {
    case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
         .networkConnectionLost, .notConnectedToInternet, .resourceUnavailable:
        true
    default:
        false
    }
}
