import Foundation

enum ConsensusRoleJSONError: Error, Equatable {
    case missingJSONObject(role: String)
    case decodeFailed(role: String)
}

enum ConsensusRoleJSON {
    static func decode<T: Decodable>(_ type: T.Type, from text: String, role: String) throws -> T {
        guard let object = extractJSONObject(from: text) else {
            throw ConsensusRoleJSONError.missingJSONObject(role: role)
        }
        do {
            return try JSONCoding.decoder().decode(T.self, from: Data(object.utf8))
        } catch {
            throw ConsensusRoleJSONError.decodeFailed(role: role)
        }
    }

    static func extractJSONObject(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let direct = balancedJSONObject(in: trimmed) {
            return direct
        }
        if let fenced = fencedJSONObject(in: trimmed) {
            return fenced
        }
        return nil
    }

    private static func fencedJSONObject(in text: String) -> String? {
        let segments = text.components(separatedBy: "```")
        guard segments.count >= 3 else { return nil }

        for segment in segments.dropFirst() {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            let body: String
            if trimmed.hasPrefix("json") {
                body = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                body = trimmed
            }
            if let object = balancedJSONObject(in: body) {
                return object
            }
        }
        return nil
    }

    private static func balancedJSONObject(in text: String) -> String? {
        var depth = 0
        var startIndex: String.Index?
        var inString = false
        var isEscaped = false

        for index in text.indices {
            let character = text[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                    continue
                }
                if character == "\\" {
                    isEscaped = true
                    continue
                }
                if character == "\"" {
                    inString = false
                }
                continue
            }

            if character == "\"" {
                inString = true
                continue
            }
            if character == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
                continue
            }
            if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let startIndex {
                    return String(text[startIndex...index])
                }
            }
        }

        return nil
    }
}
