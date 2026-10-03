import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KnowledgeCore

func makeWebRequest(
    urlString: String,
    timeout: TimeInterval,
    userAgent: String,
    policy: WebFetchPolicy = .default
) throws -> URLRequest {
    let url = try policy.authorize(urlString: urlString)
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    return request
}

func shouldRetry(statusCode: Int) -> Bool {
    [429, 500, 502, 503, 504].contains(statusCode)
}
