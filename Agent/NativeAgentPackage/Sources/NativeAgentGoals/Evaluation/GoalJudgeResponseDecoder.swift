import Foundation

struct GoalJudgeResponse: Decodable, Sendable, Equatable {
    let satisfied: Bool
    let blocked: Bool
    let score: Double
    let reason: String
    let nextInstruction: String

    private enum CodingKeys: String, CodingKey {
        case satisfied
        case blocked
        case score
        case reason
        case nextInstruction = "next_instruction"
    }
}

struct GoalJudgeResponseDecoder: Sendable {
    func decode(_ raw: String) throws -> GoalJudgeResponse {
        let clean = raw.trimmedForNativeAgentGoal
        let candidates = balancedJSONObjectCandidates(in: clean)
        let jsonCandidates = candidates.isEmpty ? [clean] : candidates

        for json in jsonCandidates {
            guard let data = json.data(using: .utf8) else {
                throw GoalError.invalidEvaluatorResponse(
                    "goal evaluator response was not UTF-8"
                )
            }
            if let response = try? JSONDecoder().decode(GoalJudgeResponse.self, from: data) {
                return response
            }
        }

        throw GoalError.invalidEvaluatorResponse(
            "goal evaluator response did not match JSON schema"
        )
    }

    private func balancedJSONObjectCandidates(in raw: String) -> [String] {
        var candidates: [String] = []
        var start: String.Index?
        var depth = 0
        var inString = false
        var isEscaped = false

        for index in raw.indices {
            let character = raw[index]
            if depth > 0 && inString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            if depth > 0 && character == "\"" {
                inString = true
                continue
            }
            if character == "{" {
                if depth == 0 {
                    start = index
                }
                depth += 1
                continue
            }
            if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let objectStart = start {
                    candidates.append(String(raw[objectStart...index]))
                    start = nil
                }
            }
        }

        return candidates
    }
}
