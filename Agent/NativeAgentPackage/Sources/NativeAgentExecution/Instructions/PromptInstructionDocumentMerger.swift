import Foundation
import NativeAgentDomain

struct PromptInstructionDocumentMerger: Sendable {
    func merge(_ documents: [PromptInstructionDocument]) -> [PromptInstructionDocument] {
        var effective: [PromptInstructionDocument] = []

        for document in documents {
            applyMergeMode(document.mergeMode, current: document, effective: &effective)
            effective.removeAll { $0.canonicalPath == document.canonicalPath }
            effective.append(document)
        }

        return effective
    }

    func applyMergeMode(
        _ mergeMode: InstructionDocumentMergeMode,
        current: PromptInstructionDocument,
        effective: inout [PromptInstructionDocument]
    ) {
        switch mergeMode {
        case .append:
            return
        case .replaceParent:
            guard current.kind != .global,
                  let parentIndex = effective.lastIndex(where: { $0.kind != .global }) else {
                return
            }
            effective.remove(at: parentIndex)
        case .replaceProjectChain:
            effective.removeAll { $0.kind == .project }
        }
    }
}
