import ASK
import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Maps the on-device model availability to a user-presentable reason so the
/// consumer surface can degrade gracefully instead of failing mid-session.
@available(iOS 26.0, macOS 26.0, *)
public enum ASKFoundationModelAvailability: Sendable, Equatable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case customized(String)

    public static func current() -> ASKFoundationModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable(let reason):
            return .customized(String(describing: reason))
        @unknown default:
            return .customized("unknown availability reason")
        }
    }

    public var isUsable: Bool {
        if case .available = self { return true }
        return false
    }

    public var localizedDescription: String {
        switch self {
        case .available:
            return "On-device model ready."
        case .deviceNotEligible:
            return "This device cannot run the on-device model."
        case .appleIntelligenceNotEnabled:
            return "Enable Apple Intelligence in Settings to use the on-device knowledge assistant."
        case .modelNotReady:
            return "The on-device model is still downloading or preparing."
        case .customized(let context):
            return "On-device model unavailable: \(context)"
        }
    }
}

/// Builds an on-device language-model session whose only capabilities are read-only ASK tools.
@available(iOS 26.0, macOS 26.0, *)
public enum ASKFoundationModelsSessionFactory {
    public static func makeSession(configuration: ASKConfiguration) throws -> LanguageModelSession {
        let suite = ASKFoundationModelsToolSuite(configuration: configuration)
        return LanguageModelSession(
            tools: suite.tools,
            instructions: ASKFoundationModelsToolSuite.groundedKnowledgeInstructions
        )
    }
}
#endif
