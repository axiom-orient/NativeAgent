import LanguageModelCore
import Foundation

public struct PromptAugmentationRequest: Sendable, Equatable {
    public let sessionID: String
    public let basePrompt: String?
    public let userPrompt: String
    public let title: String?
    public let modelID: String?
    public let metadata: [String: JSONValue]
    public let availableTools: [ToolDefinition]

    public init(
        sessionID: String,
        basePrompt: String? = nil,
        userPrompt: String,
        title: String? = nil,
        modelID: String? = nil,
        metadata: [String: JSONValue] = [:],
        availableTools: [ToolDefinition] = []
    ) {
        self.sessionID = sessionID
        self.basePrompt = basePrompt
        self.userPrompt = userPrompt
        self.title = title
        self.modelID = modelID
        self.metadata = metadata
        self.availableTools = availableTools
    }

    public var normalizedBasePrompt: String {
        basePrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

public protocol PromptAugmentor: Sendable {
    func augmentSystemPrompt(_ request: PromptAugmentationRequest) async throws -> String?
}

/// Optional, request-only rendering of the active user message, for example decoding a native
/// editorial envelope into prose. Return nil to retain the original typed content. Durable
/// input stays unchanged; the projected text participates in request limits and effect identity.
/// Only `turnPromptAugmentors` invoke this hook. Implementations must be deterministic and free
/// of external effects; tools remain the effect/permission boundary.
public protocol TurnInputProjector: Sendable {
    func projectUserPrompt(_ request: PromptAugmentationRequest) async throws -> String?
}

/// Applies prompt augmentors in declaration order.
///
/// Each augmentor receives the previous augmentor's output as its base prompt,
/// while all other request fields remain unchanged. An empty chain preserves
/// the normalized base prompt.
public struct PromptAugmentorChain: PromptAugmentor, TurnInputProjector {
    private let augmentors: [any PromptAugmentor]

    public init(_ augmentors: [any PromptAugmentor]) {
        self.augmentors = augmentors
    }

    public func augmentSystemPrompt(_ request: PromptAugmentationRequest) async throws -> String? {
        var currentPrompt: String? = request.basePrompt

        for augmentor in augmentors {
            currentPrompt = try await augmentor.augmentSystemPrompt(
                PromptAugmentationRequest(
                    sessionID: request.sessionID,
                    basePrompt: currentPrompt,
                    userPrompt: request.userPrompt,
                    title: request.title,
                    modelID: request.modelID,
                    metadata: request.metadata,
                    availableTools: request.availableTools
                )
            )
        }

        let normalized = currentPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    public func projectUserPrompt(_ request: PromptAugmentationRequest) async throws -> String? {
        var projection: String?
        for augmentor in augmentors {
            guard let projector = augmentor as? any TurnInputProjector,
                  let candidate = try await projector.projectUserPrompt(request) else { continue }
            guard projection == nil else {
                throw AgentError.invalidConfiguration("Only one turn input projector may own a user message.")
            }
            projection = candidate
        }
        return projection
    }
}
