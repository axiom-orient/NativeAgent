import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

package enum TutorGatewayTask: String, Sendable {
    case explain
    case solve
    case practice
    case grade
    case plan
}

package enum TutorGatewayRequestBuilder {
    static func build<Payload: Encodable>(
        baseURL: URL,
        task: TutorGatewayTask,
        payload: Payload,
        authTokenProvider: (@Sendable () async throws -> String?)?,
        timeout: TimeInterval
    ) async throws -> URLRequest {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1/tutor/generate"),
            timeoutInterval: timeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = try await authTokenProvider?() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try TutorGatewayCodec.encodeEnvelope(task: task.rawValue, payload: payload)
        return request
    }
}

package enum TutorGatewayCodec {
    static func encodeEnvelope<Payload: Encodable>(task: String, payload: Payload) throws -> Data {
        let encoder = JSONEncoder()
        return try encoder.encode(GatewayEnvelope(task: task, payload: payload))
    }

    static func decodeResult<Response: Decodable>(_ type: Response.Type, from data: Data, response: URLResponse) throws -> Response {
        guard let http = response as? HTTPURLResponse else {
            throw ASKTutorError.model("gateway returned a non-HTTP response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let diagnosticLimit = 4_096
            let bodyPrefix = String(decoding: data.prefix(diagnosticLimit), as: UTF8.self)
            let body = data.count > diagnosticLimit ? "\(bodyPrefix)…" : bodyPrefix
            throw ASKTutorError.model("gateway status \(http.statusCode): \(body)")
        }
        let decoder = JSONDecoder()
        return try decoder.decode(GatewayResult<Response>.self, from: data).result
    }
}

private struct GatewayEnvelope<Payload: Encodable>: Encodable {
    var task: String
    var payload: Payload
}

private struct GatewayResult<Response: Decodable>: Decodable {
    var result: Response
}
