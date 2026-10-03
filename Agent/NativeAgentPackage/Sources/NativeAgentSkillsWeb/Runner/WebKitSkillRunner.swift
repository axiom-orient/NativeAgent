import NativeAgentDomain
import NativeAgentSkills
import Foundation

#if canImport(WebKit)
import WebKit

@MainActor
public final class WebKitSkillRunner: NSObject, SkillScriptRunner {
    private let policy: WebKitSkillRunnerPolicy

    public init(policy: WebKitSkillRunnerPolicy = .localPure) {
        self.policy = policy
    }

    public func run(
        skill: ManagedSkill,
        scriptURL: URL,
        readAccessURL: URL?,
        inputJSON: String,
        secret: String?,
        context: ToolExecutionContext
    ) async throws -> SkillScriptResponse {
        let unsupported = policy.unsupportedCapabilities(
            for: skill.capabilityRequirements,
            exposesSecret: secret?.isEmpty == false
        )
        guard unsupported.isEmpty else {
            throw WebKitSkillRunnerError.policyViolation(
                "skill \(skill.name) requires capabilities outside local run_js: "
                    + unsupported.joined(separator: ", ")
            )
        }

        let inputSize = Data(inputJSON.utf8).count
        guard inputSize <= policy.maxInputBytes else {
            throw WebKitSkillRunnerError.inputTooLarge(
                inputSize,
                limit: policy.maxInputBytes
            )
        }

        let rawResult = try await WebKitExecutor.execute(
            scriptURL: scriptURL,
            readAccessURL: readAccessURL,
            inputJSON: inputJSON,
            policy: policy
        )
        let outputSize = Data(rawResult.utf8).count
        guard outputSize <= policy.maxOutputBytes else {
            throw WebKitSkillRunnerError.outputTooLarge(
                outputSize,
                limit: policy.maxOutputBytes
            )
        }
        guard let response = try? JSONDecoder().decode(
            SkillScriptResponse.self,
            from: Data(rawResult.utf8)
        ) else {
            throw WebKitSkillRunnerError.invalidJSON
        }
        return response
    }
}
#endif
