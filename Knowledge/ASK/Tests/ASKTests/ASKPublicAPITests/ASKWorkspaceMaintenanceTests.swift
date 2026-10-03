import Foundation
import Testing
@testable import ASK

/// Full-root integration tests. Require the root package's existing dependency graph.
struct ASKWorkspaceMaintenanceTests {
    @Test func realCommandsUseOneLeaseAndEscapedSessionCannotMutate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("# Recovery\n\nRecovery evidence.\n".utf8).write(to: source.appendingPathComponent("note.md"))
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: root.appendingPathComponent("workspace")))
        let command = ASKCommand.indexWorkspace(ASKIndexWorkspaceCommand(sourceRootURL: source))
        let escaped = try await client.withWorkspaceMaintenance(actionID: "test-maintenance") { session in
            let competing = ASKClient(configuration: client.configuration)
            await #expect(throws: ASKDiagnostic.self) { try await competing.apply(competing.plan(command)) }
            _ = try await session.apply(command)
            _ = try await session.apply(command)
            _ = try await session.query(.pendingWork(ASKPendingWorkQuery()))
            return session
        }
        await #expect(throws: ASKDiagnostic.self) { try await escaped.apply(command) }
        _ = try await client.apply(client.plan(command)) // The scope released ownership.
    }

    @Test func typedRetrievalCanInspectExactVersionAfterUpdateAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("note.md")
        try Data("# Recovery\n\nOriginal recovery evidence.\n".utf8).write(to: file)
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: root.appendingPathComponent("workspace")))
        let command = ASKCommand.indexWorkspace(ASKIndexWorkspaceCommand(sourceRootURL: source))
        _ = try await client.apply(client.plan(command))
        let result = try await client.query(.retrieveEvidence(ASKEvidenceRetrieveQuery(question: "recovery")))
        guard case .evidenceRetrieved(let evidence) = result else { Issue.record("Unexpected query result"); return }
        let item = try #require(evidence.evidence.first)
        let checksum = item.sourceVersionChecksum
        try Data("# Recovery\n\nChanged recovery evidence.\n".utf8).write(to: file)
        _ = try await client.apply(client.plan(command))
        try FileManager.default.removeItem(at: file)
        _ = try await client.apply(client.plan(command))
        let exact = try await client.query(.sourceInspect(ASKSourceInspectQuery(sourceID: item.sourceID,
            start: item.rangeStart, end: item.rangeEnd, sourceVersionChecksum: checksum)))
        guard case .sourceInspect(let inspected) = exact else { Issue.record("Unexpected inspection result"); return }
        #expect(inspected.checksum == checksum)
        await #expect(throws: ASKDiagnostic.self) {
            try await client.query(.sourceInspect(ASKSourceInspectQuery(sourceID: item.sourceID)))
        }
    }
}
extension ASKWorkspaceMaintenanceTests {
    @Test func maintenanceCannotBorrowItsLeaseForAnUnreservedPresentationRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let outside = root.appendingPathComponent("outside")
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
        do {
            _ = try await client.withWorkspaceMaintenance(actionID: "bounded") { session in
                try await session.apply(.decidePatch(.init(
                    workspace: ASKWorkspaceSelection(productWorkspaceURL: outside),
                    patchID: "unwritten", decision: .approved, decidedAt: "2026-09-06T00:00:00Z", reason: "reviewed")))
            }
            Issue.record("A maintenance lease cannot expand its output authority")
        } catch let diagnostic as ASKDiagnostic {
            #expect(diagnostic.code == .conflict)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func alreadyCancelledApplyHasNoEffects() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
        let plan = try client.plan(.quickStart(.init(requestedAt: "2026-09-06T00:00:00Z")))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.apply(plan)
        }
        do { _ = try await task.value; Issue.record("Cancelled apply must fail before writes") }
        catch let diagnostic as ASKDiagnostic {
            #expect(diagnostic.context["reason"] == "cancelled")
            #expect(diagnostic.context["actionID"] == plan.actionID)
        }
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
    }
}
