import Foundation
import NativeAgentDomain

extension SkillRuntime {
    public func runJS(
        skillName: String,
        scriptName: String,
        dataJSONString: String,
        callID: String,
        context: ToolExecutionContext
    ) async throws -> ToolResult {
        switch try await prepareRunJSExecution(
            skillName: skillName,
            scriptName: scriptName,
            dataJSONString: dataJSONString,
            callID: callID
        ) {
        case let .earlyReturn(result):
            return result
        case let .ready(plan):
            let response: SkillScriptResponse
            do {
                response = try await scriptRunner.run(
                    skill: plan.skill,
                    scriptURL: plan.scriptURL,
                    readAccessURL: plan.readAccessURL,
                    inputJSON: plan.inputJSON,
                    secret: plan.secret,
                    context: context
                )
            } catch {
                // Only a classified definite failure may become a completed tool result.
                // Timeout, cancellation, and unclassified host errors leave the external
                // outcome unknown so the effect journal requires reconciliation.
                if EffectFailureClassifier.certainty(for: error) == .outcomeUnknown {
                    throw error
                }
                return resultBuilder.scriptErrorResult(
                    skill: plan.skill,
                    scriptName: plan.scriptName,
                    error: error.localizedDescription,
                    callID: callID
                )
            }
            return try await finalizeRunJSExecution(
                plan: plan,
                response: response,
                callID: callID
            )
        }
    }

    func prepareRunJSExecution(
        skillName: String,
        scriptName: String,
        dataJSONString: String,
        callID: String
    ) async throws -> RunJSPreparationOutcome {
        guard let skill = try await selectedSkill(named: skillName) else {
            return .earlyReturn(
                resultBuilder.missingSkillResult(
                    callID: callID,
                    toolName: "run_js",
                    skillName: skillName,
                    scriptName: scriptName
                )
            )
        }
        guard skill.isExecutionAvailable else {
            return .earlyReturn(
                .text(
                    callID: callID,
                    toolName: "run_js",
                    content: skill.executionSupportReason.ifEmpty("Skill execution is unavailable on this platform."),
                    isError: true,
                    metadata: [
                        "errorCode": .string(ToolFailureCode.unsupported.rawValue),
                        "skillName": .string(skill.name),
                        "scriptName": .string(scriptName),
                        "executionSupport": .string(skill.executionSupport.rawValue)
                    ]
                )
            )
        }

        let secret = try await resolveSecret(
            for: skill,
            scriptName: scriptName,
            callID: callID
        )
        switch secret {
        case let .available(secretValue):
            async let scriptURL = scriptURLResolver(skill, scriptName)
            async let readAccessURL = readAccessURLResolver(skill)
            return .ready(
                RunJSExecutionPlan(
                    skill: skill,
                    scriptName: scriptName,
                    scriptURL: try await scriptURL,
                    readAccessURL: try await readAccessURL,
                    inputJSON: dataJSONString.normalizedJSONPayload,
                    secret: secretValue
                )
            )
        case let .missing(result):
            return .earlyReturn(result)
        }
    }

    func finalizeRunJSExecution(
        plan: RunJSExecutionPlan,
        response: SkillScriptResponse,
        callID: String
    ) async throws -> ToolResult {

        if let error = response.error, !error.isEmpty {
            return resultBuilder.scriptErrorResult(
                skill: plan.skill,
                scriptName: plan.scriptName,
                error: error,
                callID: callID
            )
        }

        return try resultBuilder.scriptSuccessResult(
            skill: plan.skill,
            scriptName: plan.scriptName,
            response: response,
            resolvedWebViewURL: try await resolveWebViewURL(for: plan.skill, response: response),
            callID: callID
        )
    }

    func resolveSecret(
        for skill: ManagedSkill,
        scriptName: String,
        callID: String
    ) async throws -> RunJSSecretResolution {
        guard skill.requiresSecret else {
            return .available(nil)
        }

        let secret = try await secretReader(skill.name)
        guard let secret, !secret.isEmpty else {
            return .missing(
                resultBuilder.missingSecretResult(
                    skill: skill,
                    scriptName: scriptName,
                    callID: callID
                )
            )
        }
        return .available(secret)
    }

    func resolveReadAccessURL(for skill: ManagedSkill) async throws -> URL? {
        try await readAccessURLResolver(skill)
    }

    func resolveWebViewURL(
        for skill: ManagedSkill,
        response: SkillScriptResponse
    ) async throws -> URL? {
        guard let webview = response.webview else {
            return nil
        }
        let url = webview.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            return nil
        }
        return try await webViewURLResolver(skill, url)
    }


}

struct RunJSExecutionPlan {
    let skill: ManagedSkill
    let scriptName: String
    let scriptURL: URL
    let readAccessURL: URL?
    let inputJSON: String
    let secret: String?
}

enum RunJSPreparationOutcome {
    case ready(RunJSExecutionPlan)
    case earlyReturn(ToolResult)
}

enum RunJSSecretResolution {
    case available(String?)
    case missing(ToolResult)
}
