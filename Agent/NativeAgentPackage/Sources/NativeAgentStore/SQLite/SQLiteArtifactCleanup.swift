import Foundation

extension SQLiteSessionStore {
    func removeUnreferencedArtifactFiles() throws {
        let sessionRows = try requiredDatabase.query(
            "SELECT session_id FROM sessions ORDER BY session_id ASC"
        )

        for row in sessionRows {
            let sessionID = try row.text(0)
            let directoryURL = layout.artifactsDirectoryURL(sessionID: sessionID)
            guard fileManager.fileExists(atPath: directoryURL.path) else {
                continue
            }
            _ = try sandboxGuard.validateFileURL(directoryURL)

            let referencedRows = try requiredDatabase.query(
                "SELECT filename FROM session_artifacts WHERE session_id = ?",
                parameters: [.text(sessionID)]
            )
            let referenced = Set(try referencedRows.map { try $0.text(0) })
            let files = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )

            for fileURL in files where referenced.contains(fileURL.lastPathComponent) == false {
                let values = try fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true else {
                    continue
                }
                let validated = try sandboxGuard.validateFileURL(fileURL)
                try fileManager.removeItem(at: validated)
            }
        }
    }
}
