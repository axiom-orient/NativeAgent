import NativeAgentDomain

enum ToolFailureClassifier {
    static func code(for error: any Error) -> ToolFailureCode {
        if let preflight = error as? ToolPreflightFailure {
            return preflight.code
        }
        if let agentError = error as? AgentError {
            return agentError.defaultToolFailureCode
        }
        if EffectFailureClassifier.certainty(for: error) == .outcomeUnknown {
            return .unknownOutcome
        }
        return .temporaryFailure
    }
}

func toolFailureMetadata(_ code: ToolFailureCode) -> [String: JSONValue] {
    ["errorCode": .string(code.rawValue)]
}

func toolFailureMetadata(for error: any Error) -> [String: JSONValue] {
    let code = ToolFailureClassifier.code(for: error)
    var metadata = toolFailureMetadata(code)

    if let preflight = error as? ToolPreflightFailure {
        metadata["operation"] = .string(preflight.operation)
        metadata["cause"] = .string(preflight.cause)
        metadata["effectCertainty"] = .string(preflight.effectFailureCertainty.rawValue)
        metadata["context"] = .object(preflight.context.mapValues(JSONValue.string))
        return metadata
    }
    guard let effectFailure = error as? EffectFailure else {
        return metadata
    }
    metadata["operation"] = .string(effectFailure.operation)
    metadata["cause"] = .string(effectFailure.cause)
    metadata["effectCertainty"] = .string(effectFailure.effectFailureCertainty.rawValue)
    metadata["context"] = .object(effectFailure.context.mapValues(JSONValue.string))
    return metadata
}
