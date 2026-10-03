import Foundation
import NativeAgentDomain
import LanguageModelCore

package struct SkillSupportingFileRead: Sendable, Hashable {
    static let defaultCharactersPerRead = 16_384
    static let maximumCharactersPerRead = 32_768

    let relativePath: String
    let content: String
    let characterOffset: Int
    let nextCharacterOffset: Int?
    let totalCharacters: Int
    let byteCount: Int
    let contentSHA256: String

    var jsonValue: JSONValue {
        .object([
            "relativePath": .string(relativePath),
            "content": .string(content),
            "characterOffset": .integer(Int64(characterOffset)),
            "nextCharacterOffset": nextCharacterOffset.map { .integer(Int64($0)) } ?? .null,
            "totalCharacters": .integer(Int64(totalCharacters)),
            "byteCount": .integer(Int64(byteCount)),
            "contentSHA256": .string(contentSHA256),
            "truncated": .bool(nextCharacterOffset != nil),
        ])
    }

    static func make(
        relativePath: String,
        data: Data,
        characterOffset: Int,
        maxCharacters: Int
    ) throws -> SkillSupportingFileRead {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentError.invalidToolCall("Skill supporting file is not valid UTF-8: \(relativePath)")
        }
        guard characterOffset >= 0 else {
            throw AgentError.invalidToolCall("character_offset must be >= 0")
        }
        guard (1...maximumCharactersPerRead).contains(maxCharacters) else {
            throw AgentError.invalidToolCall(
                "max_characters must be between 1 and \(maximumCharactersPerRead)"
            )
        }

        let totalCharacters = text.count
        guard characterOffset <= totalCharacters else {
            throw AgentError.invalidToolCall(
                "character_offset \(characterOffset) exceeds file length \(totalCharacters)"
            )
        }

        let start = text.index(text.startIndex, offsetBy: characterOffset)
        let endOffset = min(totalCharacters, characterOffset + maxCharacters)
        let end = text.index(text.startIndex, offsetBy: endOffset)
        let content = String(text[start..<end])
        let next = endOffset < totalCharacters ? endOffset : nil

        return SkillSupportingFileRead(
            relativePath: relativePath,
            content: content,
            characterOffset: characterOffset,
            nextCharacterOffset: next,
            totalCharacters: totalCharacters,
            byteCount: data.count,
            contentSHA256: SHA256HexDigest.digest(data)
        )
    }
}
