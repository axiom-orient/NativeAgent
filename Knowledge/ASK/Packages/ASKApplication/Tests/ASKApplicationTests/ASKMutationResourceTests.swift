import Foundation
import Testing
@testable import ASKApplication

struct ASKMutationResourceTests {
    @Test func configurationIdentitySurvivesDirectoryCreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("vault")
        let index = root.appendingPathComponent("index")
        let before = ASKApplicationConfiguration(vaultURL: vault, evidenceIndexURL: index)
        let owner = ASKApplicationMutationCoordinator()
        let lease = try await owner.begin(actionID: "create", configuration: before)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        let after = ASKApplicationConfiguration(vaultURL: vault, evidenceIndexURL: index)
        #expect(before == after)
        #expect(Set([before, after]).count == 1)
        #expect(lease.configuration == after)
        #expect(await owner.isActive(lease))
        #expect(await owner.finish(lease))
    }

    @Test func overlappingResourcesShareOneLaneAndStaleFinishCannotReleaseIt() async throws {
        let owner = ASKApplicationMutationCoordinator()
        let root = URL(fileURLWithPath: "/tmp/ask-lane-" + UUID().uuidString)
        let first = ASKApplicationConfiguration(vaultURL: root.appendingPathComponent("vault"), evidenceIndexURL: root.appendingPathComponent("index"))
        let lease = try await owner.begin(actionID: "backup", configuration: first, additionalProtectedRoots: [root])
        for second in [
            ASKApplicationConfiguration(vaultURL: first.vaultURL, evidenceIndexURL: root.appendingPathComponent("other-index")),
            ASKApplicationConfiguration(vaultURL: root.appendingPathComponent("other-vault"), evidenceIndexURL: first.evidenceIndexURL),
            ASKApplicationConfiguration(vaultURL: root.appendingPathComponent("nested/vault"))
        ] {
            await #expect(throws: ASKApplicationError.mutationInProgress(actionID: "backup")) {
                try await owner.begin(actionID: "mutate", configuration: second)
            }
        }
        let independent = try await owner.begin(actionID: "independent",
            configuration: ASKApplicationConfiguration(vaultURL: root.appendingPathExtension("other")))
        #expect(await owner.finish(independent))
        let forged = ASKApplicationMutationLease(actionID: lease.actionID, configuration: lease.configuration, token: UUID())
        #expect(await owner.finish(forged) == false)
        #expect(await owner.isActive(lease))
        #expect(await owner.finish(lease))
        #expect(await owner.finish(lease) == false)
        let next = try await owner.begin(actionID: "next", configuration: first)
        #expect(await owner.finish(next))
    }

    @Test func canonicalSymlinkAliasesConflict() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real"), alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let owner = ASKApplicationMutationCoordinator()
        let lease = try await owner.begin(actionID: "real", configuration: ASKApplicationConfiguration(vaultURL: real))
        await #expect(throws: ASKApplicationError.mutationInProgress(actionID: "real")) {
            try await owner.begin(actionID: "alias", configuration: ASKApplicationConfiguration(vaultURL: alias))
        }
        #expect(await owner.finish(lease))
    }
}
extension ASKMutationResourceTests {
    @Test func sharedPresentationRootConflictsEvenWithDistinctVaultAndIndex() async throws {
        let owner = ASKApplicationMutationCoordinator()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let output = root.appendingPathComponent("presentation")
        let lease = try await owner.begin(actionID: "first",
            configuration: ASKApplicationConfiguration(vaultURL: root.appendingPathComponent("vault-a")),
            additionalProtectedRoots: [output])
        await #expect(throws: ASKApplicationError.mutationInProgress(actionID: "first")) {
            try await owner.begin(actionID: "second",
                configuration: ASKApplicationConfiguration(vaultURL: root.appendingPathComponent("vault-b")),
                additionalProtectedRoots: [output])
        }
        #expect(await owner.finish(lease))
    }

    @Test func borrowedLeaseCannotExpandItsReservedFootprint() async throws {
        let owner = ASKApplicationMutationCoordinator()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lease = try await owner.begin(actionID: "maintenance",
            configuration: ASKApplicationConfiguration(vaultURL: root.appendingPathComponent("vault")),
            additionalProtectedRoots: [root.appendingPathComponent("product")])
        #expect(await owner.isActive(lease, protecting: [root.appendingPathComponent("product/pages")]))
        #expect(await owner.isActive(lease, protecting: [root]) == false)
        #expect(await owner.isActive(lease, protecting: [root.appendingPathComponent("product-sibling")]) == false)
        #expect(await owner.finish(lease))
        #expect(await owner.isActive(lease, protecting: [root.appendingPathComponent("product")]) == false)
    }
}
