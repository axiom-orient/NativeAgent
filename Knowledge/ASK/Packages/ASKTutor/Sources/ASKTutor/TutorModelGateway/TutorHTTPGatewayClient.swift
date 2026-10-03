import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct TutorHTTPGatewayConfiguration: Sendable {
    public var baseURL: URL
    public var session: URLSession
    public var authTokenProvider: (@Sendable () async throws -> String?)?
    /// Per-request timeout applied to the generated gateway request.
    public var requestTimeout: TimeInterval
    /// Maximum response body size accepted before decoding.
    public var maxResponseBytes: Int
    /// Allows plain HTTP only for an explicitly trusted local development endpoint.
    public var allowsInsecureHTTP: Bool

    public init(
        baseURL: URL,
        session: URLSession = .shared,
        authTokenProvider: (@Sendable () async throws -> String?)? = nil,
        requestTimeout: TimeInterval = 60,
        maxResponseBytes: Int = 10 * 1024 * 1024,
        allowsInsecureHTTP: Bool = false
    ) {
        self.baseURL = baseURL
        self.session = session
        self.authTokenProvider = authTokenProvider
        self.requestTimeout = requestTimeout
        self.maxResponseBytes = maxResponseBytes
        self.allowsInsecureHTTP = allowsInsecureHTTP
    }
}

public struct TutorHTTPGatewayClient: TutorModelClient, Sendable {
    private let configuration: TutorHTTPGatewayConfiguration

    public init(configuration: TutorHTTPGatewayConfiguration) {
        self.configuration = configuration
    }

    public func explain(_ request: TutorExplainModelRequest) async throws -> TutorNarrativeDraft {
        try await send(task: .explain, payload: request, responseType: TutorNarrativeDraft.self)
    }

    public func solve(_ request: TutorExplainModelRequest) async throws -> TutorNarrativeDraft {
        try await send(task: .solve, payload: request, responseType: TutorNarrativeDraft.self)
    }

    public func makePracticeSet(_ request: TutorPracticeModelRequest) async throws -> TutorPracticeDraft {
        try await send(task: .practice, payload: request, responseType: TutorPracticeDraft.self)
    }

    public func grade(_ request: TutorGradeModelRequest) async throws -> TutorGradeDraft {
        try await send(task: .grade, payload: request, responseType: TutorGradeDraft.self)
    }

    public func plan(_ request: TutorPlanModelRequest) async throws -> TutorPlanDraft {
        try await send(task: .plan, payload: request, responseType: TutorPlanDraft.self)
    }

    private func send<Payload: Encodable, Response: Decodable>(
        task: TutorGatewayTask,
        payload: Payload,
        responseType: Response.Type
    ) async throws -> Response {
        let baseURL = try authorizedBaseURL()
        let request = try await TutorGatewayRequestBuilder.build(
            baseURL: baseURL,
            task: task,
            payload: payload,
            authTokenProvider: configuration.authTokenProvider,
            timeout: configuration.requestTimeout
        )
        let (data, response) = try await fetch(request)
        return try TutorGatewayCodec.decodeResult(responseType, from: data, response: response)
    }

    private func authorizedBaseURL() throws -> URL {
        guard let scheme = configuration.baseURL.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && configuration.allowsInsecureHTTP) else {
            throw ASKTutorError.model("tutor gateway base URL must use https; enable allowsInsecureHTTP only for trusted local development")
        }
        guard let host = configuration.baseURL.host, !host.isEmpty else {
            throw ASKTutorError.model("tutor gateway base URL must include a host")
        }
        guard configuration.requestTimeout.isFinite, configuration.requestTimeout > 0 else {
            throw ASKTutorError.model("tutor gateway requestTimeout must be finite and positive")
        }
        guard configuration.maxResponseBytes > 0 else {
            throw ASKTutorError.model("tutor gateway maxResponseBytes must be positive")
        }
        return configuration.baseURL
    }

    private func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let delegate = TutorGatewayRedirectDelegate(
            baseURL: configuration.baseURL,
            allowsInsecureHTTP: configuration.allowsInsecureHTTP
        )
        do {
            #if canImport(Darwin)
            let (stream, response) = try await configuration.session.bytes(for: request, delegate: delegate)
            try validateDeclaredLength(response)
            var data = Data()
            data.reserveCapacity(min(configuration.maxResponseBytes, 1 << 16))
            for try await byte in stream {
                data.append(byte)
                try validateResponseSize(data.count)
            }
            return (data, response)
            #else
            let (data, response) = try await configuration.session.data(for: request, delegate: delegate)
            try validateDeclaredLength(response)
            try validateResponseSize(data.count)
            return (data, response)
            #endif
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    private func validateDeclaredLength(_ response: URLResponse) throws {
        let declared = response.expectedContentLength
        guard declared != NSURLSessionTransferSizeUnknown,
              declared > Int64(configuration.maxResponseBytes) else {
            return
        }
        throw ASKTutorError.model("tutor gateway response body exceeds the \(configuration.maxResponseBytes) byte limit")
    }

    private func validateResponseSize(_ count: Int) throws {
        guard count <= configuration.maxResponseBytes else {
            throw ASKTutorError.model("tutor gateway response body exceeds the \(configuration.maxResponseBytes) byte limit")
        }
    }
}

private final class TutorGatewayRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let baseHost: String
    private let basePort: Int?
    private let baseScheme: String
    private let allowsInsecureHTTP: Bool

    init(baseURL: URL, allowsInsecureHTTP: Bool) {
        self.baseHost = baseURL.host?.lowercased() ?? ""
        self.basePort = Self.effectivePort(for: baseURL)
        self.baseScheme = baseURL.scheme?.lowercased() ?? ""
        self.allowsInsecureHTTP = allowsInsecureHTTP
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && allowsInsecureHTTP),
              scheme == baseScheme,
              url.host?.lowercased() == baseHost,
              Self.effectivePort(for: url) == basePort else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}
