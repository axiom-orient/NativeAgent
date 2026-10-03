import Foundation

extension ASKCommandPlan {
    /// Vault/index are always protected by the coordinator. Include the other
    /// resources actually written by this command, not external read inputs.
    var mutationRoots: [URL] {
        switch command {
        case .quickStart, .importWorkspace:
            // These workflows can reset the workspace before publication.
            return [context.workspaceURL, context.productWorkspaceURL]
        case .decidePatch, .repairPresentation:
            return [context.productWorkspaceURL]
        default:
            return []
        }
    }
}
