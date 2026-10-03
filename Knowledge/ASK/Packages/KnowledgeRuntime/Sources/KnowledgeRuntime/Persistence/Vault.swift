import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import KnowledgeCore

package struct RebuildReport: Sendable, Equatable {
    package var approvedPatchIDs: [String]
    package var rejectedPatchIDs: [String]
    package var pendingPatchIDs: [String]
    package var mirrorCounts: [String: Int]

    package init(approvedPatchIDs: [String], rejectedPatchIDs: [String], pendingPatchIDs: [String], mirrorCounts: [String: Int]) {
        self.approvedPatchIDs = approvedPatchIDs
        self.rejectedPatchIDs = rejectedPatchIDs
        self.pendingPatchIDs = pendingPatchIDs
        self.mirrorCounts = mirrorCounts
    }
}

package struct ApplyResult: Sendable, Equatable {
    package var patchID: String
    package var decision: String
    package var rebuild: RebuildReport

    package init(patchID: String, decision: String, rebuild: RebuildReport) {
        self.patchID = patchID
        self.decision = decision
        self.rebuild = rebuild
    }
}

package struct ApplyDecisionSummary: Sendable, Equatable {
    package var patchID: String
    package var decision: String

    package init(patchID: String, decision: String) {
        self.patchID = patchID
        self.decision = decision
    }
}

package struct BatchApplyFailure: Sendable, Equatable {
    package var patchID: String
    package var message: String

    package init(patchID: String, message: String) {
        self.patchID = patchID
        self.message = message
    }
}

/// Outcome of committing several decisions under one materialization.
/// `applied` lists what reached the journal; `failure` names the decision that
/// stopped the batch, if any. Everything in `applied` is committed regardless.
package struct BatchApplyResult: Sendable, Equatable {
    package var applied: [ApplyDecisionSummary]
    package var rebuild: RebuildReport
    package var failure: BatchApplyFailure?

    package init(applied: [ApplyDecisionSummary], rebuild: RebuildReport, failure: BatchApplyFailure?) {
        self.applied = applied
        self.rebuild = rebuild
        self.failure = failure
    }
}

package struct VaultDumpState: Sendable, Equatable {
    package var approvedPatchIDs: [String]
    package var rejectedPatchIDs: [String]
    package var pendingPatchIDs: [String]
    package var authorityRecords: [String: AuthorityStateSnapshot]
    package var projectionStates: [String: [ProjectionState]]
    package var visibleProjections: [String: VisibleProjectionSnapshot]
    package var searchDocs: [String: SearchDocRow]
    package var mirrorCounts: [String: Int]
    package var files: [String]

    package init(
        approvedPatchIDs: [String],
        rejectedPatchIDs: [String],
        pendingPatchIDs: [String],
        authorityRecords: [String: AuthorityStateSnapshot],
        projectionStates: [String: [ProjectionState]],
        visibleProjections: [String: VisibleProjectionSnapshot],
        searchDocs: [String: SearchDocRow],
        mirrorCounts: [String: Int],
        files: [String]
    ) {
        self.approvedPatchIDs = approvedPatchIDs
        self.rejectedPatchIDs = rejectedPatchIDs
        self.pendingPatchIDs = pendingPatchIDs
        self.authorityRecords = authorityRecords
        self.projectionStates = projectionStates
        self.visibleProjections = visibleProjections
        self.searchDocs = searchDocs
        self.mirrorCounts = mirrorCounts
        self.files = files
    }
}

package struct AuthorityStateSnapshot: Codable, Sendable, Equatable {
    package var approvalState: AuthorityState
    package var effectiveFrom: String
    package var effectiveTo: String?
    package var supersedesID: String?

    package init(approvalState: AuthorityState, effectiveFrom: String, effectiveTo: String?, supersedesID: String?) {
        self.approvalState = approvalState
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
        self.supersedesID = supersedesID
    }
}

package struct VisibleProjectionSnapshot: Codable, Sendable, Equatable {
    package var state: ProjectionState
    package var title: String
    package var space: ProjectionSpace

    package init(state: ProjectionState, title: String, space: ProjectionSpace) {
        self.state = state
        self.title = title
        self.space = space
    }
}

package struct Vault: Sendable {
    package let root: URL

    package init(root: URL) {
        self.root = root
    }

    package init(rootPath: String) {
        self.root = URL(fileURLWithPath: rootPath, isDirectory: true)
    }

    package func mirrorURL() -> URL {
        root.appendingPathComponent("mirror/knowledge.sqlite")
    }

    package func patchDirectory(_ patchID: String) -> URL {
        root.appendingPathComponent(".ask/journal/patches/\(patchID)", isDirectory: true)
    }

    package func eventURL(_ logID: String) -> URL {
        root.appendingPathComponent(".ask/journal/events/\(logID).json")
    }

    package func materializeLockURL() -> URL {
        root.appendingPathComponent(".ask/materialize.lock")
    }

    package func generationMarkerURL() -> URL {
        root.appendingPathComponent(".ask/generation/canonical.json")
    }

    package func isTransientPath(_ relativePath: String) throws -> Bool {
        try isTransientPersistencePath(relativePath)
    }

    package func createDirectory(_ relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: try validatedVaultURL(root.appendingPathComponent(relativePath, isDirectory: true)),
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    package func writeTextFile(_ url: URL, content: String) throws {
        let validatedURL = try validatedVaultURL(url)
        try FileManager.default.createDirectory(at: validatedURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        let encoded = content + (content.hasSuffix("\n") ? "" : "\n")
        guard let data = encoded.data(using: .utf8) else {
            throw ASKError.validation("failed to encode UTF-8 text content")
        }
        try data.write(to: validatedURL, options: .atomic)
    }

    package func writeJSONFile<T: Encodable>(_ url: URL, payload: T) throws {
        let validatedURL = try validatedVaultURL(url)
        try FileManager.default.createDirectory(at: validatedURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        let data = try CanonicalJSON.data(for: payload) + Data([0x0a])
        try data.write(to: validatedURL, options: .atomic)
    }

    package func writeBytesFile(_ url: URL, content: Data) throws {
        let validatedURL = try validatedVaultURL(url)
        try FileManager.default.createDirectory(at: validatedURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try content.write(to: validatedURL, options: .atomic)
    }

    package func validatedVaultURL(_ url: URL) throws -> URL {
        let candidate = url.standardizedFileURL
        let rootURL = root.standardizedFileURL
        let rootPath = canonicalPath(for: rootURL.path)
        let candidatePath = canonicalPath(for: candidate.path)
        let isInsideRoot = candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
        guard isInsideRoot else {
            throw ASKError.validation("persistence path escapes vault root")
        }
        return candidate
    }

    private func canonicalPath(for path: String) -> String {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        var unresolvedSuffix: [String] = []
        var existingPath = standardizedPath

        while !FileManager.default.fileExists(atPath: existingPath), existingPath != "/" {
            unresolvedSuffix.append(URL(fileURLWithPath: existingPath).lastPathComponent)
            let parent = (existingPath as NSString).deletingLastPathComponent
            existingPath = parent.isEmpty ? "/" : parent
        }

        let resolvedExistingPath = existingPath.withCString { pointer -> String? in
            guard let resolvedPointer = realpath(pointer, nil) else { return nil }
            defer { free(resolvedPointer) }
            return String(cString: resolvedPointer)
        } ?? URL(fileURLWithPath: existingPath).resolvingSymlinksInPath().standardizedFileURL.path

        return unresolvedSuffix.reversed().reduce(resolvedExistingPath) { partialPath, component in
            URL(fileURLWithPath: partialPath).appendingPathComponent(component).path
        }
    }
}

package func curatedNoteExcerpt(_ noteText: String, maxLength: Int = 280) -> String {
    let lines = noteText
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter {
            !$0.isEmpty
                && !$0.hasPrefix("#")
                && !$0.hasPrefix("- source_id:")
                && !$0.hasPrefix("- url:")
                && !$0.hasPrefix("- observed_at:")
                && !$0.hasPrefix("- connector:")
                && !$0.hasPrefix("- canonical_url:")
                && !$0.hasPrefix("- fragment_count:")
        }
    let merged = lines.joined(separator: " ")
    if merged.count <= maxLength { return merged }
    return String(merged.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
}

package func jsonLiteral(_ value: String?) -> String {
    if let value {
        return yamlDoubleQuotedScalar(value)
    }
    return "null"
}

package func sha256Prefixed(_ data: Data) -> String {
    ASKSHA256.prefixedDigest(data)
}

package enum AnyEncodableValue: Encodable {
    case string(String)

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        }
    }
}
