import Foundation
import Testing
@testable import ASKApplication

struct ASKApplicationBoundaryTests {
    @Test
    func runtimeCreationDoesNotCreateWorkspaceAndMissingIndexFailsBeforeEffects() async throws {
        let root = temporaryDirectory("missing-index")
        defer { try? FileManager.default.removeItem(at: root) }
        let application = ASKApplicationRuntime()
        let configuration = ASKApplicationConfiguration(vaultURL: root)
        #expect(!FileManager.default.fileExists(atPath: root.path))

        await #expect(throws: ASKApplicationError.missingEvidenceIndexPath) {
            _ = try await application.workWikiRuntime(configuration: configuration)
        }
        #expect(await application.activeMutationActionID(configuration: configuration) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test
    func mutationReducerAcceptsOnlyTheCurrentLease() {
        let configuration = ASKApplicationConfiguration(
            vaultURL: temporaryDirectory("reducer-vault"),
            evidenceIndexURL: temporaryDirectory("reducer-index")
        )
        let first = ASKApplicationMutationLease(
            actionID: "first",
            configuration: configuration,
            token: UUID()
        )
        let second = ASKApplicationMutationLease(
            actionID: "second",
            configuration: configuration,
            token: UUID()
        )

        #expect(ASKApplicationMutationReducer.reduce(
            state: .idle,
            event: .begin(first)
        ) == .accepted(.active(first)))
        #expect(ASKApplicationMutationReducer.reduce(
            state: .active(first),
            event: .begin(second)
        ) == .rejected(.mutationInProgress(actionID: "first")))
        #expect(ASKApplicationMutationReducer.reduce(
            state: .active(first),
            event: .finish(second)
        ) == .rejected(.staleLease))
        #expect(ASKApplicationMutationReducer.reduce(
            state: .active(first),
            event: .finish(first)
        ) == .accepted(.idle))
    }

    @Test
    func applicationMutationLaneRejectsOverlapAndExposesStaleRelease() async throws {
        let configuration = ASKApplicationConfiguration(
            vaultURL: temporaryDirectory("lease-vault"),
            evidenceIndexURL: temporaryDirectory("lease-index")
        )
        let application = ASKApplicationRuntime()
        let first = try await application.beginMutation(
            actionID: "first",
            configuration: configuration
        )

        await #expect(throws: ASKApplicationError.mutationInProgress(actionID: "first")) {
            _ = try await application.beginMutation(
                actionID: "second",
                configuration: configuration
            )
        }

        let stale = ASKApplicationMutationLease(
            actionID: "first",
            configuration: configuration,
            token: UUID()
        )
        let staleReleased = await application.finishMutation(stale)
        #expect(!staleReleased)
        #expect(await application.activeMutationActionID(configuration: configuration) == "first")

        #expect(await application.finishMutation(first))
        #expect(await application.activeMutationActionID(configuration: configuration) == nil)
    }

    @Test
    func distinctWorkspaceMutationLanesRemainIndependent() async throws {
        let firstConfiguration = ASKApplicationConfiguration(
            vaultURL: temporaryDirectory("lane-one-vault"),
            evidenceIndexURL: temporaryDirectory("lane-one-index")
        )
        let secondConfiguration = ASKApplicationConfiguration(
            vaultURL: temporaryDirectory("lane-two-vault"),
            evidenceIndexURL: temporaryDirectory("lane-two-index")
        )
        let application = ASKApplicationRuntime()

        let first = try await application.beginMutation(
            actionID: "first",
            configuration: firstConfiguration
        )
        let second = try await application.beginMutation(
            actionID: "second",
            configuration: secondConfiguration
        )

        #expect(await application.activeMutationActionID(configuration: firstConfiguration) == "first")
        #expect(await application.activeMutationActionID(configuration: secondConfiguration) == "second")
        #expect(await application.finishMutation(first))
        #expect(await application.finishMutation(second))
    }

    @Test
    func separateApplicationInstancesShareOneWorkspaceMutationLane() async throws {
        let configuration = ASKApplicationConfiguration(
            vaultURL: temporaryDirectory("shared-lane-vault"),
            evidenceIndexURL: temporaryDirectory("shared-lane-index")
        )
        let firstApplication = ASKApplicationRuntime()
        let secondApplication = ASKApplicationRuntime()
        let first = try await firstApplication.beginMutation(
            actionID: "first",
            configuration: configuration
        )

        await #expect(throws: ASKApplicationError.mutationInProgress(actionID: "first")) {
            _ = try await secondApplication.beginMutation(
                actionID: "second",
                configuration: configuration
            )
        }
        #expect(await secondApplication.activeMutationActionID(configuration: configuration) == "first")
        #expect(await secondApplication.finishMutation(first))
        #expect(await firstApplication.activeMutationActionID(configuration: configuration) == nil)
    }


}

private func temporaryDirectory(_ suffix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ask-application-\(suffix)-\(UUID().uuidString)", isDirectory: true)
}
