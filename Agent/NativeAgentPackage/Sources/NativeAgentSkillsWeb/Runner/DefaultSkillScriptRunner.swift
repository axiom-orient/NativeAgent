import NativeAgentDomain
import NativeAgentSkills
import Foundation

#if canImport(WebKit)
import WebKit
#endif

public enum DefaultSkillScriptRunner {
    /// Returns the local-pure WebKit runner when WebKit exists. Unsupported
    /// platforms fail explicitly; execution never falls back to an effectful
    /// or unconfined engine.
    @MainActor
    public static func make(
        policy: WebKitSkillRunnerPolicy = .localPure
    ) -> any SkillScriptRunner {
        #if canImport(WebKit)
        return WebKitSkillRunner(policy: policy)
        #else
        return UnsupportedSkillScriptRunner()
        #endif
    }
}

public struct UnsupportedSkillScriptRunner: SkillScriptRunner {
    public init() {}

    public func run(
        skill: ManagedSkill,
        scriptURL: URL,
        readAccessURL: URL?,
        inputJSON: String,
        secret: String?,
        context: ToolExecutionContext
    ) async throws -> SkillScriptResponse {
        throw AgentError.unsupportedSurface(
            "This platform does not provide the local WebKit skill execution surface for \(skill.name)."
        )
    }
}
