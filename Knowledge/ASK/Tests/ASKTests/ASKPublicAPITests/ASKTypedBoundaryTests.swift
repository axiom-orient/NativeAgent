import Foundation
import KnowledgeCore
import XCTest
@testable import ASK

final class ASKTypedBoundaryTests: XCTestCase {
    func testPendingPresentationRepairCanBeDiscoveredAfterRelaunch() async throws {
        let workspace = temporaryDirectory("pending-repair-query")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let configuration = ASKConfiguration(workspaceURL: workspace)
        let token = ASKPresentationRepairTokenFactory.make(
            actionID: "ask-test-repair",
            knowledgeRootURL: configuration.resolvedVaultURL,
            productWorkspaceURL: configuration.resolvedProductWorkspaceURL,
            projectionSlugs: ["work/reports/recovery"],
            createdAt: "2026-08-23T00:00:00Z"
        )
        try ASKPresentationRepairStore(
            productWorkspaceURL: configuration.resolvedProductWorkspaceURL
        ).save(ASKPresentationRepairRecord(
            token: token,
            committed: nil,
            diagnostic: nil,
            state: .pending
        ))

        let relaunched = ASKClient(configuration: configuration)
        let result = try await relaunched.query(.pendingWork(ASKPendingWorkQuery()))
        guard case .pendingWork(let pending) = result else {
            return XCTFail("Expected pending work")
        }
        XCTAssertEqual(pending.presentationRepairs, [token])
    }

    func testTypedQuickStartPlanIsDeterministicAndDryRunIsEffectFree() throws {
        let workspace = temporaryDirectory("typed-dry-run")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
        let command = ASKCommand.quickStart(ASKQuickStartCommand(
            workspace: ASKWorkspaceSelection(workspaceURL: workspace),
            requestedAt: "2026-07-26T01:00:00Z",
            resetExistingWorkspace: true
        ))

        let first = try client.plan(command)
        let second = try client.plan(command)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try client.dryRun(first).actionID, first.actionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
    }

    /// The facade must accept exactly what the domain accepts; a second timestamp
    /// validator here previously rejected fractional seconds that `ASKTimestamp` allows.
    func testPlanTimestampAcceptanceMatchesTheDomainValidator() throws {
        let workspace = temporaryDirectory("timestamp-parity")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))

        for timestamp in ["2026-07-26T00:00:00Z", "2026-07-26T00:00:00.500Z", "2026-07-26T09:00:00+09:00"] {
            XCTAssertTrue(
                ASKTimestamp.isValidRFC3339(timestamp),
                "fixture \(timestamp) must be valid for this test to mean anything"
            )
            XCTAssertNoThrow(
                try client.plan(.quickStart(ASKQuickStartCommand(requestedAt: timestamp))),
                "planning rejected \(timestamp), which the domain accepts"
            )
        }

        for timestamp in ["", "not-a-timestamp", "2026-07-26"] {
            XCTAssertThrowsError(try client.plan(.quickStart(ASKQuickStartCommand(requestedAt: timestamp)))) { error in
                XCTAssertEqual((error as? ASKDiagnostic)?.operation, .plan)
            }
        }
    }

    func testPlanRejectsNonFileURLsAtTheTypedBoundary() throws {
        let workspace = temporaryDirectory("non-file-url")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
        let remote = URL(string: "https://example.com/workspace")!

        XCTAssertThrowsError(try client.plan(.quickStart(ASKQuickStartCommand(
            workspace: ASKWorkspaceSelection(workspaceURL: remote),
            requestedAt: "2026-07-26T02:00:00Z"
        )))) { error in
            let diagnostic = error as? ASKDiagnostic
            XCTAssertEqual(diagnostic?.code, .invalidRequest)
            XCTAssertEqual(diagnostic?.context["field"], "workspace.workspaceURL")
        }

        XCTAssertThrowsError(try client.plan(.importWorkspace(ASKImportWorkspaceCommand(
            sourceRootURL: remote,
            title: "Remote path",
            queryText: "should reject",
            requestedAt: "2026-07-26T02:01:00Z"
        )))) { error in
            let diagnostic = error as? ASKDiagnostic
            XCTAssertEqual(diagnostic?.code, .invalidRequest)
            XCTAssertEqual(diagnostic?.context["field"], "sourceRootURL")
        }
    }

    func testQueryRejectsNonFileWorkspaceURLAtTheTypedBoundary() async throws {
        let workspace = temporaryDirectory("non-file-query-url")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
        let remote = URL(string: "https://example.com/workspace")!

        do {
            _ = try await client.query(.storageHealth(ASKStorageHealthQuery(
                workspace: ASKWorkspaceSelection(workspaceURL: remote)
            )))
            XCTFail("Expected non-file query workspace URL to be rejected")
        } catch let diagnostic as ASKDiagnostic {
            XCTAssertEqual(diagnostic.code, .invalidRequest)
            XCTAssertEqual(diagnostic.operation, .query)
            XCTAssertEqual(diagnostic.context["field"], "workspace.workspaceURL")
        }
    }

    func testTypedQuickStartHonorsManagedRoutesInsideWorkspace() async throws {
        let workspace = temporaryDirectory("managed-routes")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let vault = workspace.appendingPathComponent("canonical", isDirectory: true)
        let index = workspace.appendingPathComponent("evidence", isDirectory: true)
        let product = workspace.appendingPathComponent("presentation", isDirectory: true)
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
        let command = ASKCommand.quickStart(ASKQuickStartCommand(
            workspace: ASKWorkspaceSelection(
                workspaceURL: workspace,
                vaultURL: vault,
                indexURL: index,
                productWorkspaceURL: product
            ),
            requestedAt: "2026-07-26T03:00:00Z",
            resetExistingWorkspace: true
        ))

        let outcome = try await client.apply(try client.plan(command))
        guard case .workspaceApplied(let result) = outcome else {
            return XCTFail("Expected workspaceApplied, got \(outcome)")
        }
        XCTAssertEqual(result.vaultURL.standardizedFileURL, vault.standardizedFileURL)
        XCTAssertEqual(result.indexURL.standardizedFileURL, index.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: product.path))
    }

    func testWorkspaceCreationRejectsManagedRoutesOutsideWorkspaceBeforeEffects() throws {
        let base = temporaryDirectory("route-rejection")
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        let externalVault = base.appendingPathComponent("external-vault", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
        let command = ASKCommand.quickStart(ASKQuickStartCommand(
            workspace: ASKWorkspaceSelection(workspaceURL: workspace, vaultURL: externalVault),
            requestedAt: "2026-07-26T04:00:00Z"
        ))

        XCTAssertThrowsError(try client.plan(command)) { error in
            let diagnostic = error as? ASKDiagnostic
            XCTAssertEqual(diagnostic?.code, .invalidRequest)
            XCTAssertEqual(diagnostic?.context["field"], "vaultURL")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalVault.path))
    }

    func testFailedEffectReleasesMutationLaneForNextCommand() async throws {
        let workspace = temporaryDirectory("failure-release")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
        let failing = ASKCommand.stageReport(ASKStageReportCommand(
            workspace: ASKWorkspaceSelection(workspaceURL: workspace),
            title: "Missing evidence",
            queryText: "nothing is indexed",
            requestedAt: "2026-07-26T04:30:00Z"
        ))

        do {
            _ = try await client.apply(try client.plan(failing))
            XCTFail("Expected report staging to fail without indexed evidence")
        } catch let diagnostic as ASKDiagnostic {
            XCTAssertEqual(diagnostic.context["causeCode"], "no_fresh_evidence")
            XCTAssertNil(diagnostic.context["activeActionID"])
        }

        let recovery = ASKCommand.quickStart(ASKQuickStartCommand(
            workspace: ASKWorkspaceSelection(workspaceURL: workspace),
            requestedAt: "2026-07-26T04:31:00Z",
            resetExistingWorkspace: true
        ))
        let outcome = try await client.apply(try client.plan(recovery))
        guard case .workspaceApplied = outcome else {
            return XCTFail("Expected next command to acquire the released mutation lane")
        }
    }

    /// The product root is written to (repair records, reading bundles), so it is a
    /// managed route and must be contained like the vault and index roots.
    func testWorkspaceCreationRejectsAnExternalProductRoute() throws {
        let base = temporaryDirectory("external-product")
        defer { try? FileManager.default.removeItem(at: base) }
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))

        XCTAssertThrowsError(try client.plan(.quickStart(ASKQuickStartCommand(
            workspace: ASKWorkspaceSelection(workspaceURL: workspace, productWorkspaceURL: outside),
            requestedAt: "2026-07-26T06:00:00Z"
        )))) { error in
            XCTAssertEqual((error as? ASKDiagnostic)?.code, .invalidRequest)
            XCTAssertEqual((error as? ASKDiagnostic)?.context["field"], "productWorkspaceURL")
        }
    }

    /// Planning can only compare paths lexically, so a symlink that lives inside the
    /// workspace but points outside it must still be refused before any effect runs.
    func testWorkspaceCreationRejectsSymlinkedManagedRouteBeforeEffects() async throws {
        let base = temporaryDirectory("symlink-route")
        defer { try? FileManager.default.removeItem(at: base) }
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        let escaped = base.appendingPathComponent("escaped-vault", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: escaped, withIntermediateDirectories: true)

        let link = workspace.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: escaped)

        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
        let plan = try client.plan(.quickStart(ASKQuickStartCommand(
            workspace: ASKWorkspaceSelection(workspaceURL: workspace, vaultURL: link),
            requestedAt: "2026-07-26T06:30:00Z",
            resetExistingWorkspace: true
        )))

        do {
            _ = try await client.apply(plan)
            XCTFail("Expected the symlinked vault route to be refused")
        } catch let diagnostic as ASKDiagnostic {
            XCTAssertEqual(diagnostic.code, .invalidRequest)
            XCTAssertEqual(diagnostic.context["field"], "vaultURL")
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: escaped.path), [])
    }

    func testRepairPresentationRejectsTokenRoutesOutsideConfiguredWorkspace() throws {
        let base = temporaryDirectory("repair-route-rejection")
        defer { try? FileManager.default.removeItem(at: base) }
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        let externalVault = base.appendingPathComponent("external-vault", isDirectory: true)
        let externalProduct = base.appendingPathComponent("external-product", isDirectory: true)
        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
        let token = ASKPresentationRepairTokenFactory.make(
            actionID: "ask-external-repair",
            knowledgeRootURL: externalVault,
            productWorkspaceURL: externalProduct,
            projectionSlugs: ["current/example"],
            createdAt: "2026-07-26T06:45:00Z"
        )

        XCTAssertThrowsError(try client.plan(.repairPresentation(ASKRepairPresentationCommand(
            token: token,
            requestedAt: "2026-07-26T06:46:00Z"
        )))) { error in
            XCTAssertEqual((error as? ASKDiagnostic)?.code, .invalidRequest)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalVault.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalProduct.path))
    }

    func testCommittedPresentationFailureProducesRepairTokenAndRepairIsIdempotent() async throws {
        let base = temporaryDirectory("repair")
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        // The product root has to stay inside the workspace, so materialization is blocked
        // by nesting it under a file the vault itself writes: creating a directory below a
        // regular file fails, which is what drives the repair-required outcome.
        let blockingFile = workspace
            .appendingPathComponent("vault", isDirectory: true)
            .appendingPathComponent("index.md")
        let blockedProduct = blockingFile.appendingPathComponent("product", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
        let command = ASKCommand.quickStart(ASKQuickStartCommand(
            workspace: ASKWorkspaceSelection(
                workspaceURL: workspace,
                productWorkspaceURL: blockedProduct
            ),
            requestedAt: "2026-07-26T05:00:00Z",
            resetExistingWorkspace: true
        ))

        let outcome = try await client.apply(try client.plan(command))
        let committed: ASKWorkspaceApplyResult
        let token: ASKPresentationRepairToken
        guard case .committedWithRepairRequired(.workspace(let value), let requirement) = outcome else {
            return XCTFail("Expected committedWithRepairRequired, got \(outcome)")
        }
        committed = value
        token = requirement.token
        XCTAssertEqual(requirement.diagnostic.recovery, .inspectStorage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: committed.vaultURL.path))

        let projection = try await client.query(.projection(ASKProjectionQuery(
            workspace: ASKWorkspaceSelection(vaultURL: committed.vaultURL),
            slug: committed.projectionSlug
        )))
        guard case .projection(let projectionValue) = projection else {
            return XCTFail("Expected committed projection")
        }
        XCTAssertEqual(projectionValue.slug, committed.projectionSlug)

        // Clearing the blocking file lets the same repair token materialize for real.
        try FileManager.default.removeItem(at: blockingFile)
        let repairCommand = ASKCommand.repairPresentation(ASKRepairPresentationCommand(
            token: token,
            requestedAt: "2026-07-26T05:01:00Z"
        ))
        let repairPlan = try client.plan(repairCommand)

        let firstRepair = try await client.apply(repairPlan)
        guard case .presentationRepaired(let first) = firstRepair else {
            return XCTFail("Expected presentationRepaired")
        }
        XCTAssertFalse(first.alreadyCompleted)
        XCTAssertEqual(first.materializedProjectionCount, 1)

        let secondRepair = try await client.apply(repairPlan)
        guard case .presentationRepaired(let second) = secondRepair else {
            return XCTFail("Expected idempotent presentationRepaired")
        }
        XCTAssertTrue(second.alreadyCompleted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blockedProduct
            .appendingPathComponent(".ask/repairs/\(token.id).json").path))
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-typed-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }
}
