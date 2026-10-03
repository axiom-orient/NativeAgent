import Foundation
import NativeAgentDomain

struct PromptInstructionDocumentParser: Sendable {
    func parse(_ rawText: String) -> (content: String, mergeMode: InstructionDocumentMergeMode) {
        let normalized = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            return ("", .append)
        }

        let lines = normalized.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == InstructionDocumentFrontMatter.delimiter,
              let closingIndex = lines.dropFirst().firstIndex(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == InstructionDocumentFrontMatter.delimiter
              }) else {
            return (normalized, .append)
        }

        let frontMatterLines = Array(lines[1..<closingIndex])
        let bodyLines: [String]
        if closingIndex < lines.index(before: lines.endIndex) {
            bodyLines = Array(lines[(closingIndex + 1)...])
        } else {
            bodyLines = []
        }
        let mergeMode = parseMergeMode(frontMatterLines)
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (body, mergeMode)
    }

    func parseMergeMode(_ lines: [String]) -> InstructionDocumentMergeMode {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(InstructionDocumentFrontMatter.mergeModeKey) else {
                continue
            }
            let rawValue = trimmed
                .dropFirst(InstructionDocumentFrontMatter.mergeModeKey.count)
                .drop(while: { $0 == ":" || $0 == " " || $0 == "\t" })
            return InstructionDocumentMergeMode.parse(String(rawValue))
        }
        return .append
    }
}
