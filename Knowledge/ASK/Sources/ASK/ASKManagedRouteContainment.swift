import Foundation

/// Authoritative containment check for managed workspace routes.
///
/// Planning verifies containment lexically because it is contractually free of I/O. A
/// lexical prefix accepts a symlink that lives inside the workspace but points outside
/// it, so the same routes are re-checked here, immediately before any effect runs.
///
/// The resolver walks to the deepest existing ancestor, resolves symlinks there, then
/// re-attaches the components that do not exist yet — routes are usually created by the
/// very workflow being authorized, so requiring them to exist would reject valid input.
enum ASKManagedRouteContainment {
    static func verify(_ plan: ASKCommandPlan, configuration: ASKConfiguration) throws {
        switch plan.command {
        case .quickStart, .importWorkspace:
            break
        case .indexWorkspace:
            try verifyIndexRoute(plan.context)
            return
        case .repairPresentation(let value):
            try verifyRepairRoutes(value.token, configuration: configuration)
            return
        case .stageReport, .closeDay, .importCapture, .decidePatch, .rebuildKnowledge,
             .recordDecisionMemory, .recordDecisionMemories, .transitionDecisionMemory, .consolidateDecisionMemory:
            return
        }

        let context = plan.context
        let workspacePath = resolvedPath(context.workspaceURL)
        let managedRoutes = [
            ("indexURL", context.indexURL),
            ("vaultURL", context.vaultURL),
            ("productWorkspaceURL", context.productWorkspaceURL),
        ]

        for (field, url) in managedRoutes {
            let routePath = resolvedPath(url)
            guard routePath.hasPrefix(workspacePath + "/") else {
                throw ASKDiagnostic(
                    code: .invalidRequest,
                    operation: .apply,
                    message: "\(field) resolves outside workspaceURL and cannot be written by a workspace creation workflow",
                    context: [
                        "field": field,
                        "workspacePath": workspacePath,
                        "resolvedPath": routePath,
                        "declaredPath": url.path,
                    ],
                    recovery: .correctInput
                )
            }
        }
    }

    private static func verifyIndexRoute(_ context: ASKPlanContext) throws {
        let workspacePath = resolvedPath(context.workspaceURL)
        let routePath = resolvedPath(context.indexURL)
        guard routePath.hasPrefix(workspacePath + "/") else {
            throw ASKDiagnostic(
                code: .invalidRequest,
                operation: .apply,
                message: "indexURL resolves outside workspaceURL and cannot be written by source indexing",
                context: [
                    "workspacePath": workspacePath,
                    "resolvedPath": routePath,
                    "declaredPath": context.indexURL.path,
                ],
                recovery: .correctInput
            )
        }
    }

    private static func verifyRepairRoutes(
        _ token: ASKPresentationRepairToken,
        configuration: ASKConfiguration
    ) throws {
        let workspacePath = resolvedPath(configuration.workspaceURL)
        let configuredRoutes = [
            ("knowledgeRootURL", token.knowledgeRootURL, configuration.resolvedVaultURL),
            ("productWorkspaceURL", token.productWorkspaceURL, configuration.resolvedProductWorkspaceURL),
        ]

        for (field, route, configuredRoute) in configuredRoutes {
            let routePath = resolvedPath(route)
            let configuredPath = resolvedPath(configuredRoute)
            guard routePath == configuredPath || routePath.hasPrefix(workspacePath + "/") else {
                throw ASKDiagnostic(
                    code: .invalidRequest,
                    operation: .apply,
                    message: "\(field) resolves outside workspaceURL and cannot be written by a presentation repair",
                    context: [
                        "field": field,
                        "workspacePath": workspacePath,
                        "resolvedPath": routePath,
                        "configuredPath": configuredPath,
                        "declaredPath": route.path,
                    ],
                    recovery: .correctInput
                )
            }
        }
    }

    /// Resolves symlinks as far as the path exists, keeping components that do not.
    static func resolvedPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var missing: [String] = []

        while !FileManager.default.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { break }
            missing.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }

        var resolved = existing.resolvingSymlinksInPath()
        for component in missing {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }
}
