import Foundation

func prepareWorkWikiWorkspace(_ workspaceURL: URL, reset: Bool, preserving sourceRootURL: URL? = nil) throws {
    let fileManager = FileManager.default
    if let sourceRootURL {
        let workspacePath = workspaceURL.path
        let sourceRootPath = sourceRootURL.path
        if sourceRootPath == workspacePath
            || sourceRootPath.hasPrefix(workspacePath + "/")
            || workspacePath.hasPrefix(sourceRootPath + "/") {
            throw ASKWorkWikiError(.sourceWorkspaceOverlap, "from-existing-workspace requires workspaceURL and sourceRootURL to be separate non-overlapping paths", context: ["workspacePath": workspacePath, "sourceRootPath": sourceRootPath])
        }
    }
    if fileManager.fileExists(atPath: workspaceURL.path) {
        if reset {
            try fileManager.removeItem(at: workspaceURL)
        } else if try isDirectoryEmpty(workspaceURL) == false {
            throw ASKWorkWikiError(.workspaceAlreadyExists, "workspace already exists and is not empty; pass resetExistingWorkspace or choose another path", context: ["workspacePath": workspaceURL.path])
        }
    }
    try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
}

private func isDirectoryEmpty(_ url: URL) throws -> Bool {
    try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty
}

extension ASKWorkWikiQuickStartRunner {
    func prepareWorkspace(_ workspaceURL: URL, reset: Bool, preserving sourceRootURL: URL? = nil) throws {
        try prepareWorkWikiWorkspace(workspaceURL, reset: reset, preserving: sourceRootURL)
    }

    func writeQuickStartEvidence(to url: URL, updatedAt: String) throws {
        let markdown = """
        ---
        scope: work
        kind: worklog
        topic: quickstart
        status: active
        updated_at: \(updatedAt)
        tags: [quickstart, onboarding]
        ---
        # 2026-04-20 Work Log

        ## Done
        - Shipped the onboarding quick-start path for WorkWiki.
        - Verified that evidence indexing returns source-backed hits.

        ## Decisions
        - Keep the package path narrow: evidence, report, approval, wiki output.

        ## Next
        - Connect a separate host package only if an application surface is needed; this package remains headless.
        """
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }
}
