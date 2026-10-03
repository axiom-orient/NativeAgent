import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KnowledgeCore

func decodeFetchedResponse(
    data: Data,
    response: URLResponse,
    originalURL: String
) throws -> FetchedResponse {
    guard let http = response as? HTTPURLResponse else {
        throw ASKError.validation("non-http response for `\(originalURL)`")
    }
    guard (200..<300).contains(http.statusCode) else {
        if shouldRetry(statusCode: http.statusCode) {
            throw RetryableWebFetchError(
                diagnostic: ASKError.validation("http status \(http.statusCode) for `\(originalURL)`")
            )
        }
        throw ASKError.validation("http status \(http.statusCode) for `\(originalURL)`")
    }
    let html = decodeHTML(data: data)
    return FetchedResponse(
        originalURL: originalURL,
        finalURL: http.url?.absoluteString ?? originalURL,
        statusCode: http.statusCode,
        contentType: headerValue("Content-Type", from: http),
        html: html
    )
}

struct RetryableWebFetchError: Error {
    let diagnostic: Error
}

func headerValue(_ name: String, from response: HTTPURLResponse) -> String? {
    if let exact = response.allHeaderFields[name] as? String {
        return exact
    }
    let lower = name.lowercased()
    for (key, value) in response.allHeaderFields {
        if String(describing: key).lowercased() == lower {
            return String(describing: value)
        }
    }
    return nil
}

func decodeHTML(data: Data) -> String {
    if let html = String(data: data, encoding: .utf8) {
        return html
    }
    return String(decoding: data, as: UTF8.self)
}
