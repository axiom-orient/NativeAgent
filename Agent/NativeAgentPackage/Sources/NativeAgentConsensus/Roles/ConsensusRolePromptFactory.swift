import Foundation

public enum ConsensusRole: String, Codable, Sendable, Equatable {
    case constructor
    case verifier
    case challenger
}

public struct ConsensusRolePolicy: Codable, Sendable, Equatable {
    public let systemPrefix: String?
    public let temperature: Double?
    public let maxTokens: Int?
    public let metadata: [String: String]

    public init(
        systemPrefix: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        self.systemPrefix = systemPrefix
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.metadata = metadata
    }
}

public struct ConsensusTriadPolicy: Codable, Sendable, Equatable {
    public let constructor: ConsensusRolePolicy
    public let verifier: ConsensusRolePolicy
    public let challenger: ConsensusRolePolicy

    public init(
        constructor: ConsensusRolePolicy = .init(temperature: 0.2, maxTokens: 1_200),
        verifier: ConsensusRolePolicy = .init(temperature: 0.1, maxTokens: 1_200),
        challenger: ConsensusRolePolicy = .init(temperature: 0.1, maxTokens: 1_200)
    ) {
        self.constructor = constructor
        self.verifier = verifier
        self.challenger = challenger
    }
}

enum ConsensusRolePromptFactory {
    static func makeRequest(role: ConsensusRole, input: RoundInput, policy: ConsensusRolePolicy) -> ConsensusRoleRequest {
        let system = [
            TextUtil.normalizeOptional(policy.systemPrefix),
            roleSystemInstruction(role),
            "Be concise. Do not repeat entries or describe the output schema. Use empty arrays when there is nothing to list. Return one JSON object only. Include EVERY field named in the contract and required by the schema. Use [] for empty arrays; never omit required fields such as assumptions or evidenceRefs.",
            "Keep the output bounded, precise, and directly reusable by a consensus engine."
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")

        let metadata = policy.metadata.merging([
            ConsensusRoleRequestKeys.role: role.rawValue,
            ConsensusRoleRequestKeys.round: String(input.round),
            ConsensusRoleRequestKeys.engine: BACEngine.engineShortName
        ]) { _, new in new }

        return ConsensusRoleRequest(
            system: system,
            user: roleUserPrompt(role: role, input: input),
            jsonSchema: schema(role: role),
            temperature: policy.temperature,
            maxTokens: policy.maxTokens,
            metadata: metadata
        )
    }

    private static func roleSystemInstruction(_ role: ConsensusRole) -> String {
        switch role {
        case .constructor:
            return "You are the Constructor. Produce a concrete, minimal plan that addresses the observed issue."
        case .verifier:
            return "You are the Verifier. Evaluate the proposal for correctness, concrete risks, and required follow-up actions. A pass verdict requires requiredActions and blockers to be empty arrays. An abort verdict requires at least one concrete blocker. List only actual unresolved actions; never create an action saying that no action is needed."
        case .challenger:
            return "You are the Challenger. Search for failure modes, safer options, and edge cases. A clear verdict requires requiredActions and concerns to be empty arrays. An abort verdict requires at least one concrete concern. List only actual unresolved actions; never create an action saying that no action is needed."
        }
    }

    private static func roleUserPrompt(role: ConsensusRole, input: RoundInput) -> String {
        var lines: [String] = []
        lines.append("Objective: \(input.problem.objective)")
        lines.append("Observed Issue: \(input.problem.observedIssue)")
        if let candidate = input.problem.candidate, !candidate.isEmpty {
            lines.append("Candidate: \(candidate)")
        }
        if !input.problem.constraints.isEmpty {
            lines.append("Constraints:")
            for value in input.problem.constraints {
                lines.append("- \(value)")
            }
        }
        if !input.problem.evidence.isEmpty {
            lines.append("Evidence:")
            for value in input.problem.evidence {
                var line = "- \(value.ref)"
                if let note = value.note, !note.isEmpty {
                    line += " — \(note)"
                }
                lines.append(line)
            }
        }
        if !input.similarCases.isEmpty {
            lines.append("Similar Cases:")
            for caseCard in input.similarCases.prefix(3) {
                lines.append("- [\(caseCard.primaryClass)] \(caseCard.title) => \(caseCard.chosenResolution)")
            }
        }
        if let delta = input.delta {
            lines.append("Previous Round Delta:")
            if let previousDecision = delta.previousDecision {
                lines.append("- previous_decision: \(previousDecision.rawValue)")
            }
            if let candidateSummary = delta.candidateSummary, !candidateSummary.isEmpty {
                lines.append("- previous_summary: \(candidateSummary)")
            }
            if !delta.requiredActions.isEmpty {
                lines.append("- required_actions: \(delta.requiredActions.map(\.label).joined(separator: ", "))")
            }
            if !delta.blockers.isEmpty {
                lines.append("- blockers: \(delta.blockers.map(\.label).joined(separator: ", "))")
            }
            if !delta.checks.isEmpty {
                lines.append("- checks: \(delta.checks.map(\.label).joined(separator: ", "))")
            }
        }
        lines.append(artifactContract(role))
        return lines.joined(separator: "\n")
    }

    private static func artifactContract(_ role: ConsensusRole) -> String {
        switch role {
        case .constructor:
            return "Return JSON with fields: summary:string, plan:[{label:string, reason?:string, owner?:string, ref?:string, precise:bool}], assumptions:[string], evidenceRefs:[string]."
        case .verifier:
            return "Return JSON with fields: summary:string, verdict:'pass'|'revise'|'abort', requiredActions:[{label:string, reason?:string, owner?:string, ref?:string, precise:bool}], blockers:[{label:string, severity?:string, reason?:string, ref?:string}], checks:[{label:string, how?:string, ref?:string}], evidenceRefs:[string]."
        case .challenger:
            return "Return JSON with fields: summary:string, verdict:'clear'|'revise'|'abort', concerns:[{label:string, severity?:string, reason?:string, ref?:string}], requiredActions:[{label:string, reason?:string, owner?:string, ref?:string, precise:bool}], saferOption:string, evidenceRefs:[string]."
        }
    }

    private static func schema(role: ConsensusRole) -> String {
        switch role {
        case .constructor:
            return #"{"type":"object","properties":{"summary":{"type":"string"},"plan":{"type":"array","items":{"type":"object","properties":{"label":{"type":"string"},"reason":{"type":["string","null"]},"owner":{"type":["string","null"]},"ref":{"type":["string","null"]},"precise":{"type":"boolean"}},"required":["label","reason","owner","ref","precise"],"additionalProperties":false},"maxItems":8},"assumptions":{"type":"array","items":{"type":"string"},"maxItems":8},"evidenceRefs":{"type":"array","items":{"type":"string"},"maxItems":8}},"required":["summary","plan","assumptions","evidenceRefs"],"additionalProperties":false}"#
        case .verifier:
            return #"{"type":"object","properties":{"summary":{"type":"string"},"verdict":{"type":"string","enum":["pass","revise","abort"]},"requiredActions":{"type":"array","items":{"type":"object","properties":{"label":{"type":"string"},"reason":{"type":["string","null"]},"owner":{"type":["string","null"]},"ref":{"type":["string","null"]},"precise":{"type":"boolean"}},"required":["label","reason","owner","ref","precise"],"additionalProperties":false},"maxItems":8},"blockers":{"type":"array","items":{"type":"object","properties":{"label":{"type":"string"},"severity":{"type":["string","null"]},"reason":{"type":["string","null"]},"ref":{"type":["string","null"]}},"required":["label","severity","reason","ref"],"additionalProperties":false},"maxItems":8},"checks":{"type":"array","items":{"type":"object","properties":{"label":{"type":"string"},"how":{"type":["string","null"]},"ref":{"type":["string","null"]}},"required":["label","how","ref"],"additionalProperties":false},"maxItems":8},"evidenceRefs":{"type":"array","items":{"type":"string"},"maxItems":8}},"required":["summary","verdict","requiredActions","blockers","checks","evidenceRefs"],"additionalProperties":false}"#
        case .challenger:
            return #"{"type":"object","properties":{"summary":{"type":"string"},"verdict":{"type":"string","enum":["clear","revise","abort"]},"concerns":{"type":"array","items":{"type":"object","properties":{"label":{"type":"string"},"severity":{"type":["string","null"]},"reason":{"type":["string","null"]},"ref":{"type":["string","null"]}},"required":["label","severity","reason","ref"],"additionalProperties":false},"maxItems":8},"requiredActions":{"type":"array","items":{"type":"object","properties":{"label":{"type":"string"},"reason":{"type":["string","null"]},"owner":{"type":["string","null"]},"ref":{"type":["string","null"]},"precise":{"type":"boolean"}},"required":["label","reason","owner","ref","precise"],"additionalProperties":false},"maxItems":8},"saferOption":{"type":"string"},"evidenceRefs":{"type":"array","items":{"type":"string"},"maxItems":8}},"required":["summary","verdict","concerns","requiredActions","saferOption","evidenceRefs"],"additionalProperties":false}"#
        }
    }
}
