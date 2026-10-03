import Foundation
import KnowledgeCore

extension Vault {
    package func loadPatchPlan(patchID: String) throws -> KnowledgePatchPlan? {
        let url = try validatedVaultURL(
            patchDirectory(patchID).appendingPathComponent("patch.json", isDirectory: false)
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try CanonicalJSON.load(KnowledgePatchPlan.self, from: url)
    }

    package func loadPatchReceipt(patchID: String) throws -> PatchDecisionReceipt? {
        let url = try validatedVaultURL(
            patchDirectory(patchID).appendingPathComponent("receipt.json", isDirectory: false)
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try CanonicalJSON.load(PatchDecisionReceipt.self, from: url)
    }
}
