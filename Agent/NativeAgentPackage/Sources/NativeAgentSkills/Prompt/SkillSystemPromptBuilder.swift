import Foundation
import NativeAgentDomain

public struct SkillSystemPromptBuilder: Sendable {
    private static let skillsPlaceholder = "___SKILLS___"

    public init() {}

    public func build(basePrompt: String, selectedSkills: [ManagedSkill]) -> String {
        let selected = selectedSkills.filter(\.selected)
        let skillsList: String
        if selected.isEmpty {
            skillsList = "- no skills selected"
        } else {
            skillsList = selected
                .sorted { $0.name < $1.name }
                .map { skill in
                    let executionNote = skill.isExecutionAvailable
                        ? ""
                        : " [execution unavailable on iOS: \(skill.executionSupportReason.ifEmpty("external scripts or tools are not supported"))]"
                    let hostPolicyNote = skill.requiresExplicitHostPolicy
                        ? " [requires explicit host policy: \(skill.hostPolicySummary)]"
                        : ""
                    return "- \(skill.name): \(skill.description)\(executionNote)\(hostPolicyNote)"
                }
                .joined(separator: "\n")
        }

        let skillToolRules = """
        Skill tool rules:
        - For explicit skill requests, call `load_skill` with the exact skill name before answering.
        - After `load_skill` returns, follow the loaded SKILL.md. Supporting-file previews are discovery hints only; when instructions depend on a listed file, use `read_skill_file` and continue with `nextCharacterOffset` until the required section is complete.
        - If loaded instructions name `run_intent`, call `run_intent` with the exact intent and JSON parameters before producing the final answer.
        - Treat `run_js` as execution through a host-supplied script runner. Do not use network access, persistent state, camera or microphone access, secrets, external navigation, or native bridges unless the loaded skill declares the capability and the host policy approves it.
        - If a skill is listed as execution unavailable on iOS, do not run external scripts or programs. Use the installed documents and available native intents, and report the limitation if it affects the answer.
        - If a tool call fails, report the exact tool and error instead of inventing a result.
        """
        let skillSection = ["Available skills:", skillsList, "", skillToolRules].joined(separator: "\n")

        if basePrompt.contains(Self.skillsPlaceholder) {
            return basePrompt.replacingOccurrences(of: Self.skillsPlaceholder, with: skillSection)
        }

        return [basePrompt, "", skillSection].joined(separator: "\n")
    }
}
