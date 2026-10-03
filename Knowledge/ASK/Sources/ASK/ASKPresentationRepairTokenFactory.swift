import Foundation
import KnowledgeCore

enum ASKPresentationRepairTokenFactory {
    static func make(
        actionID: String,
        knowledgeRootURL: URL,
        productWorkspaceURL: URL,
        projectionSlugs: [String],
        createdAt: String
    ) -> ASKPresentationRepairToken {
        let slugs = Array(Set(projectionSlugs)).sorted()
        var payload = Data()
        append("ask.presentation-repair.v1", to: &payload)
        append(actionID, to: &payload)
        append(askCanonicalFileURL(knowledgeRootURL).path, to: &payload)
        append(askCanonicalFileURL(productWorkspaceURL).path, to: &payload)
        append(createdAt, to: &payload)
        append(String(slugs.count), to: &payload)
        for slug in slugs {
            append(slug, to: &payload)
        }
        let digest = ASKSHA256.hexDigest(payload)
        return ASKPresentationRepairToken(
            id: "ask-repair-\(digest.prefix(24))",
            actionID: actionID,
            knowledgeRootURL: knowledgeRootURL,
            productWorkspaceURL: productWorkspaceURL,
            projectionSlugs: slugs,
            createdAt: createdAt
        )
    }

    static func verify(_ token: ASKPresentationRepairToken) throws {
        let expected = make(
            actionID: token.actionID,
            knowledgeRootURL: token.knowledgeRootURL,
            productWorkspaceURL: token.productWorkspaceURL,
            projectionSlugs: token.projectionSlugs,
            createdAt: token.createdAt
        )
        guard token == expected else {
            throw ASKDiagnostic(
                code: .integrityViolation,
                operation: .repair,
                message: "Presentation repair token integrity mismatch",
                context: ["tokenID": token.id],
                recovery: .correctInput
            )
        }
    }

    private static func append(_ value: String, to payload: inout Data) {
        var length = UInt64(value.utf8.count).bigEndian
        withUnsafeBytes(of: &length) { bytes in
            payload.append(contentsOf: bytes)
        }
        payload.append(contentsOf: value.utf8)
    }
}

