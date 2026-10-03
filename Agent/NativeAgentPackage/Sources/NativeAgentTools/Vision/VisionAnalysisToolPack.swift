import NativeAgentDomain
import Foundation

public struct VisionTextObservation: Codable, Sendable, Equatable {
    public let text: String
    public let confidence: Double
    public let boundingBox: VisionNormalizedRectangle

    public init(text: String, confidence: Double, boundingBox: VisionNormalizedRectangle) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

public struct VisionBarcodeObservation: Codable, Sendable, Equatable {
    public let payload: String?
    public let symbology: String
    public let confidence: Double
    public let boundingBox: VisionNormalizedRectangle

    public init(
        payload: String?,
        symbology: String,
        confidence: Double,
        boundingBox: VisionNormalizedRectangle
    ) {
        self.payload = payload
        self.symbology = symbology
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

public struct VisionNormalizedRectangle: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public protocol VisionAnalysisToolService: Sendable {
    func recognizeText(
        in imageURL: URL,
        languages: [String],
        maximumResults: Int
    ) async throws -> [VisionTextObservation]

    func detectBarcodes(
        in imageURL: URL,
        maximumResults: Int
    ) async throws -> [VisionBarcodeObservation]
}

public struct VisionAnalysisToolPack: ToolPack {
    public let packID: String
    private let service: any VisionAnalysisToolService
    private let maximumInputBytes: Int
    private let maximumResults: Int
    private let approvalPolicy: ApprovalPolicy

    public init(
        service: any VisionAnalysisToolService,
        maximumInputBytes: Int = 16 * 1_024 * 1_024,
        maximumResults: Int = 250,
        approvalPolicy: ApprovalPolicy = .requireApproval,
        packID: String = "toolpack.vision"
    ) throws {
        try validatePackID(packID)
        guard maximumInputBytes > 0 else {
            throw AgentError.invalidConfiguration("Vision maximum input bytes must be positive.")
        }
        guard (1...1_000).contains(maximumResults) else {
            throw AgentError.invalidConfiguration("Vision maximum results must be between 1 and 1000.")
        }
        self.service = service
        self.maximumInputBytes = maximumInputBytes
        self.maximumResults = maximumResults
        self.approvalPolicy = approvalPolicy
        self.packID = packID
    }

    public func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: textDefinition) { call, context in
                let request = try VisionTextRequest(arguments: call.arguments)
                let imageURL = try ToolWorkspaceFileResolver.readableFile(
                    relativePath: request.path,
                    context: context,
                    maximumByteCount: maximumInputBytes,
                    label: "Vision",
                    allowedExtensions: Self.supportedImageExtensions
                )
                let observations = try await service.recognizeText(
                    in: imageURL,
                    languages: request.languages,
                    maximumResults: maximumResults
                )
                guard observations.count <= maximumResults else {
                    throw AgentError.invariantViolation(
                        "Vision provider returned more text observations than requested."
                    )
                }
                return ToolResult(
                    callID: call.id,
                    toolName: call.name,
                    output: .object(["observations": try JSONValue.encode(observations)]),
                    metadata: ["sourcePath": .string(request.path)]
                )
            },
            ClosureToolExecutor(definition: barcodeDefinition) { call, context in
                let request = try VisionBarcodeRequest(arguments: call.arguments)
                let imageURL = try ToolWorkspaceFileResolver.readableFile(
                    relativePath: request.path,
                    context: context,
                    maximumByteCount: maximumInputBytes,
                    label: "Vision",
                    allowedExtensions: Self.supportedImageExtensions
                )
                let observations = try await service.detectBarcodes(
                    in: imageURL,
                    maximumResults: maximumResults
                )
                guard observations.count <= maximumResults else {
                    throw AgentError.invariantViolation(
                        "Vision provider returned more barcode observations than requested."
                    )
                }
                return ToolResult(
                    callID: call.id,
                    toolName: call.name,
                    output: .object(["observations": try JSONValue.encode(observations)]),
                    metadata: ["sourcePath": .string(request.path)]
                )
            },
        ]
    }

    private var textDefinition: ToolDefinition {
        ToolDefinition(
            name: "vision.recognizeText",
            description: "Recognize bounded text from an image file in the current agent session. The image never leaves the device through this tool.",
            capabilityID: .vision,
            inputSchema: ToolSchema.object(
                properties: [
                    "path": ToolSchema.string(description: "Relative image path in the current session workspace.", minLength: 1, maxLength: 1_024),
                    "languages": ToolSchema.array(
                        items: ToolSchema.string(description: "BCP-47 language identifier.", minLength: 2, maxLength: 35),
                        description: "Optional prioritized recognition languages.",
                        maxItems: 8
                    ),
                ],
                required: ["path"]
            ),
            approvalPolicy: approvalPolicy,
            effect: .readOnly,
            metadata: ["localOnly": .bool(true), "sensitiveData": .bool(true)]
        )
    }

    private var barcodeDefinition: ToolDefinition {
        ToolDefinition(
            name: "vision.detectBarcodes",
            description: "Detect bounded barcode observations from an image file in the current agent session. The image never leaves the device through this tool.",
            capabilityID: .vision,
            inputSchema: ToolSchema.object(
                properties: [
                    "path": ToolSchema.string(description: "Relative image path in the current session workspace.", minLength: 1, maxLength: 1_024),
                ],
                required: ["path"]
            ),
            approvalPolicy: approvalPolicy,
            effect: .readOnly,
            metadata: ["localOnly": .bool(true), "sensitiveData": .bool(true)]
        )
    }

    private static let supportedImageExtensions: Set<String> = [
        "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp",
    ]
}

private struct VisionTextRequest {
    let path: String
    let languages: [String]

    init(arguments: JSONValue) throws {
        let object = try requiredObject(arguments, toolName: "vision.recognizeText")
        try rejectUnknownKeys(object, allowed: ["path", "languages"], toolName: "vision.recognizeText")
        guard let path = object["path"]?.stringValue,
              path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AgentError.invalidToolCall("vision.recognizeText requires a non-empty path.")
        }
        self.path = path

        guard let languageValues = object["languages"] else {
            self.languages = []
            return
        }
        guard let array = languageValues.arrayValue, array.count <= 8 else {
            throw AgentError.invalidToolCall("vision.recognizeText languages must contain at most 8 strings.")
        }
        let languages = array.compactMap(\.stringValue)
        guard languages.count == array.count,
              languages.allSatisfy({ (2...35).contains($0.unicodeScalars.count) }) else {
            throw AgentError.invalidToolCall("vision.recognizeText languages must be BCP-47 strings.")
        }
        self.languages = languages
    }
}

private struct VisionBarcodeRequest {
    let path: String

    init(arguments: JSONValue) throws {
        let object = try requiredObject(arguments, toolName: "vision.detectBarcodes")
        try rejectUnknownKeys(object, allowed: ["path"], toolName: "vision.detectBarcodes")
        guard let path = object["path"]?.stringValue,
              path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AgentError.invalidToolCall("vision.detectBarcodes requires a non-empty path.")
        }
        self.path = path
    }
}

#if canImport(Vision)
import Vision

@available(iOS 17, *)
public actor AppleVisionAnalysisToolService: VisionAnalysisToolService {
    public init() {}

    public func recognizeText(
        in imageURL: URL,
        languages: [String],
        maximumResults: Int
    ) async throws -> [VisionTextObservation] {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        let handler = VNImageRequestHandler(url: imageURL, options: [:])
        try handler.perform([request])
        try Task.checkCancellation()

        let results = request.results ?? []
        guard results.count <= maximumResults else {
            throw AgentError.budgetExceeded(
                "Vision text observations exceed the configured result budget of \(maximumResults)."
            )
        }
        return results.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return VisionTextObservation(
                text: candidate.string,
                confidence: Double(candidate.confidence),
                boundingBox: Self.rectangle(from: observation.boundingBox)
            )
        }
    }

    public func detectBarcodes(
        in imageURL: URL,
        maximumResults: Int
    ) async throws -> [VisionBarcodeObservation] {
        try Task.checkCancellation()
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(url: imageURL, options: [:])
        try handler.perform([request])
        try Task.checkCancellation()

        let results = request.results ?? []
        guard results.count <= maximumResults else {
            throw AgentError.budgetExceeded(
                "Vision barcode observations exceed the configured result budget of \(maximumResults)."
            )
        }
        return results.map { observation in
            VisionBarcodeObservation(
                payload: observation.payloadStringValue,
                symbology: observation.symbology.rawValue,
                confidence: Double(observation.confidence),
                boundingBox: Self.rectangle(from: observation.boundingBox)
            )
        }
    }

    private static func rectangle(from rectangle: CGRect) -> VisionNormalizedRectangle {
        VisionNormalizedRectangle(
            x: Double(rectangle.origin.x),
            y: Double(rectangle.origin.y),
            width: Double(rectangle.width),
            height: Double(rectangle.height)
        )
    }
}
#endif
