import Foundation
import KnowledgePresentation

struct ASKPresentationRepairRecord: Codable, Equatable, Sendable {
    enum State: String, Codable, Equatable, Sendable {
        case pending
        case completed
    }

    let version: String
    let token: ASKPresentationRepairToken
    let committed: ASKCommittedValue?
    let diagnostic: ASKDiagnostic?
    let state: State
    let completedAt: String?

    init(
        token: ASKPresentationRepairToken,
        committed: ASKCommittedValue?,
        diagnostic: ASKDiagnostic?,
        state: State,
        completedAt: String? = nil
    ) {
        self.version = "ask.presentation-repair.v1"
        self.token = token
        self.committed = committed
        self.diagnostic = diagnostic
        self.state = state
        self.completedAt = completedAt
    }
}

struct ASKPresentationRepairStore: Sendable {
    let productWorkspaceURL: URL

    init(productWorkspaceURL: URL) {
        self.productWorkspaceURL = askCanonicalFileURL(productWorkspaceURL)
    }

    func load(token: ASKPresentationRepairToken) throws -> ASKPresentationRepairRecord? {
        let url = try recordURL(tokenID: token.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try JSONDecoder().decode(
            ASKPresentationRepairRecord.self,
            from: Data(contentsOf: url)
        )
        guard record.token == token else {
            throw ASKDiagnostic(
                code: .integrityViolation,
                operation: .repair,
                message: "Presentation repair token does not match its persisted record",
                context: ["tokenID": token.id, "path": url.path],
                recovery: .inspectStorage
            )
        }
        return record
    }

    func pendingTokens() throws -> [ASKPresentationRepairToken] {
        let directory = repairsDirectoryURL
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                let record = try JSONDecoder().decode(
                    ASKPresentationRepairRecord.self,
                    from: Data(contentsOf: url)
                )
                guard record.version == "ask.presentation-repair.v1",
                      url.deletingPathExtension().lastPathComponent == record.token.id else {
                    throw ASKDiagnostic(
                        code: .integrityViolation,
                        operation: .query,
                        message: "Presentation repair record identity mismatch",
                        context: ["path": url.path],
                        recovery: .inspectStorage
                    )
                }
                try ASKPresentationRepairTokenFactory.verify(record.token)
                return record.state == .pending ? record.token : nil
            }
    }

    func save(_ record: ASKPresentationRepairRecord) throws {
        let url = try recordURL(tokenID: record.token.id)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    private func recordURL(tokenID: String) throws -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard !tokenID.isEmpty,
              tokenID.unicodeScalars.allSatisfy(allowed.contains),
              !tokenID.contains("..") else {
            throw ASKDiagnostic(
                code: .invalidRequest,
                operation: .repair,
                message: "Invalid presentation repair token identifier",
                context: ["tokenID": tokenID],
                recovery: .correctInput
            )
        }
        return repairsDirectoryURL
            .appendingPathComponent("\(tokenID).json", isDirectory: false)
    }

    private var repairsDirectoryURL: URL {
        productWorkspaceURL
            .appendingPathComponent(".ask", isDirectory: true)
            .appendingPathComponent("repairs", isDirectory: true)
    }
}

enum ASKProjectionPresentationMaterializer {
    static func materialize(
        slugs: [String],
        knowledgeRootURL: URL,
        productWorkspaceURL: URL
    ) throws {
        guard !slugs.isEmpty else { return }
        let runtime = try ASKKnowledgeWorkspaceRuntime(
            workspace: ASKKnowledgeWorkspacePaths(rootURL: productWorkspaceURL),
            knowledgeRootURL: knowledgeRootURL
        )
        for slug in Array(Set(slugs)).sorted() {
            _ = try runtime.materializeProjectionPresentation(slug: slug)
        }
    }
}
