import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KnowledgeCore

func performWebDataRequest(
    session: URLSession,
    request: URLRequest,
    policy: WebFetchPolicy = .default
) async throws -> (Data, URLResponse) {
    let delegate = WebRedirectPolicyDelegate(policy: policy)
    do {
        #if canImport(Darwin)
        // Streaming lets an oversized body be abandoned mid-transfer instead of
        // being buffered in full before anyone can object to its size.
        let (stream, response) = try await session.bytes(for: request, delegate: delegate)
        try checkDeclaredLength(response, policy: policy, url: request.url)
        var data = Data()
        data.reserveCapacity(min(policy.maxResponseBytes, 1 << 16))
        for try await byte in stream {
            data.append(byte)
            if data.count > policy.maxResponseBytes {
                throw ASKError.validation(
                    "response body for `\(request.url?.absoluteString ?? "")` exceeds the \(policy.maxResponseBytes) byte limit"
                )
            }
        }
        return (data, response)
        #else
        let (data, response) = try await session.data(for: request, delegate: delegate)
        try checkDeclaredLength(response, policy: policy, url: request.url)
        guard data.count <= policy.maxResponseBytes else {
            throw ASKError.validation(
                "response body for `\(request.url?.absoluteString ?? "")` exceeds the \(policy.maxResponseBytes) byte limit"
            )
        }
        return (data, response)
        #endif
    } catch {
        if let urlError = error as? URLError, urlError.code == .cancelled {
            throw CancellationError()
        }
        throw error
    }
}

/// Rejects an oversized body before reading it when the server declares its length.
private func checkDeclaredLength(_ response: URLResponse, policy: WebFetchPolicy, url: URL?) throws {
    let declared = response.expectedContentLength
    guard declared != NSURLSessionTransferSizeUnknown, declared > Int64(policy.maxResponseBytes) else {
        return
    }
    throw ASKError.validation(
        "response for `\(url?.absoluteString ?? "")` declares \(declared) bytes, above the \(policy.maxResponseBytes) byte limit"
    )
}
