import Foundation
import Testing
@testable import ASK

struct ASKMutationFootprintTests {
    @Test func footprintTracksEffectsRatherThanOnlyVaultAndIndex() throws {
        let workspace = URL(fileURLWithPath: "/tmp/workspace")
        let product = workspace.appendingPathComponent("shared-product")
        let configuration = ASKConfiguration(workspaceURL: workspace, productWorkspaceURL: product)
        let create = try ASKCommandPlanner.makePlan(.quickStart(.init(requestedAt: "2026-09-06T00:00:00Z")), configuration: configuration)
        #expect(create.mutationRoots.map(\.path) == [workspace.path, product.path])
        let decision = try ASKCommandPlanner.makePlan(.decidePatch(.init(patchID: "patch", decision: .approved,
            decidedAt: "2026-09-06T00:00:00Z", reason: "reviewed")), configuration: configuration)
        #expect(decision.mutationRoots.map(\.path) == [product.path])
        let index = try ASKCommandPlanner.makePlan(.indexWorkspace(.init(sourceRootURL: URL(fileURLWithPath: "/tmp/external"))), configuration: configuration)
        #expect(index.mutationRoots.isEmpty)
    }
}
