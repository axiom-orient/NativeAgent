import Foundation
import NativeAgentDomain

extension SkillRuntime {
    public func runIntent(
        intent: String,
        parametersJSON: String,
        callID: String,
        context: ToolExecutionContext
    ) async throws -> ToolResult {
        let parameters = try decodeIntentParameters(parametersJSON)
        let definition = await intentService.toolDefinition(for: intent)
        if let definition {
            if definition.metadata["requiresSelectedSkill"]?.boolValue == true {
                let selectedSkills = try await selectedSkillsLoader()
                let isAuthorized = selectedSkills.contains { skill in
                    skill.capabilityRequirements.hostIntents.contains(intent)
                        || skill.capabilityRequirements.bridgeIntents.contains(intent)
                }
                guard isAuthorized else {
                    throw AgentError.accessDenied(
                        "Skill intent is not authorized by a selected skill: \(intent)"
                    )
                }
            }
            try SkillIntentToolSchemaValidator().validate(parameters: parameters, against: definition)
        }

        let result = try await intentService.execute(
            intent: intent,
            parametersJSON: try parameters.canonicalString(),
            context: context
        )

        var metadata = result.metadata
        metadata["intentName"] = .string(intent)
        if let definition {
            metadata["intentCapabilityID"] = .string(definition.capabilityID.rawValue)
            metadata["intentEffect"] = .string(definition.effect.rawValue)
            metadata["intentApprovalPolicy"] = .string(definition.approvalPolicy.rawValue)
        }

        return result
            .applying(.identityChanged(callID: callID, toolName: "run_intent"))
            .applying(.metadataChanged(metadata))
    }

    private func decodeIntentParameters(_ parametersJSON: String) throws -> JSONValue {
        let payload = parametersJSON.normalizedJSONPayload
        guard let data = payload.data(using: .utf8) else {
            throw AgentError.invalidToolCall("Intent parameters must be valid UTF-8 JSON")
        }
        let parameters = try JSONDecoder.nativeAgent().decode(JSONValue.self, from: data)
        guard parameters.objectValue != nil else {
            throw AgentError.invalidToolCall("Intent parameters must decode to a JSON object")
        }
        return parameters
    }
}
