import LanguageModelCore
import Foundation

package enum InstructionDocumentMergeMode: String, Codable, Sendable, Equatable, Hashable {
    case append
    case replaceParent
    case replaceProjectChain

    package static func parse(_ raw: String?) -> InstructionDocumentMergeMode {
        guard let raw else {
            return .append
        }

        switch raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-") {
        case "append", "":
            return .append
        case "replace-parent", "replace-parent-project":
            return .replaceParent
        case "replace-project-chain", "replace-all-project":
            return .replaceProjectChain
        default:
            return .append
        }
    }
}

package enum InstructionDocumentFrontMatter {
    package static let delimiter = "---"
    package static let mergeModeKey = "native-agent-merge"
}
