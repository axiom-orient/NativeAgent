import Foundation
import KnowledgeCore

public enum SourceIdentityFactory {
    public static func makeVersion(data: Data, modifiedAt: Date? = nil) -> SourceVersion {
        return SourceVersion(
            checksum: StableDigest.sha256Hex(data),
            contentLength: data.count,
            modifiedAt: modifiedAt
        )
    }

    public static func makeID(for version: SourceVersion) -> SourceID {
        SourceID.fromChecksum(version.checksum)
    }

    /// Stable logical identity for a source that is updated in place. The
    /// checksum belongs to `SourceVersion`, not to the source identity, so an
    /// update replaces the active artifact instead of growing the manifest.
    public static func makeID(logicalKey: String) -> SourceID {
        SourceID("src_\(StableDigest.sha256Hex(Data(logicalKey.utf8)))")
    }

    public static func makeID(forFileAt url: URL) -> SourceID {
        makeID(logicalKey: logicalKey(forFileAt: url))
    }

    static func logicalKey(forFileAt url: URL) -> String {
        if let key = ownedSnapshotLogicalKey(forFileAt: url) {
            return key
        }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func rootIdentity(for url: URL) -> String {
        // Resolve the root through the same owned-generation marker as each file.
        // A synthetic child handles both the generation root and a nested root.
        let suffix = "/.ask-root-scope"
        let child = logicalKey(forFileAt: url.appendingPathComponent(".ask-root-scope"))
        if child.hasSuffix(suffix) { return String(child.dropLast(suffix.count)) }
        // At the generation root the owned key ends with a colon, not a slash.
        return String(child.dropLast(".ask-root-scope".count))
    }

    static func contains(fileAt url: URL, rootIdentity: String) -> Bool {
        let key = logicalKey(forFileAt: url)
        let prefix = rootIdentity.hasSuffix(":") ? rootIdentity : rootIdentity + "/"
        return key == rootIdentity || key.hasPrefix(prefix)
    }

    private static func ownedSnapshotLogicalKey(forFileAt url: URL) -> String? {
        let fileURL = url.standardizedFileURL.resolvingSymlinksInPath()
        var directory = fileURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        while true {
            let marker = directory.appendingPathComponent(".ask-source-identity", isDirectory: false)
            if fileManager.fileExists(atPath: marker.path),
               let raw = try? String(contentsOf: marker, encoding: .utf8) {
                let identity = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let generationsRoot = directory.deletingLastPathComponent()
                let identityRoot = generationsRoot.deletingLastPathComponent()
                let importedSourcesRoot = identityRoot.deletingLastPathComponent()
                let suffix = identity.hasPrefix("root-") ? String(identity.dropFirst(5)) : ""
                guard generationsRoot.lastPathComponent == "generations",
                      identityRoot.lastPathComponent == identity,
                      importedSourcesRoot.lastPathComponent == "ASKImportedSources",
                      suffix.count == 24,
                      suffix.unicodeScalars.allSatisfy({ scalar in
                          (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
                      }) else { return nil }
                let rootPath = directory.standardizedFileURL.path
                let filePath = fileURL.standardizedFileURL.path
                guard filePath.hasPrefix(rootPath + "/") else { return nil }
                let relative = String(filePath.dropFirst(rootPath.count + 1))
                return "owned:\(identity):\(relative)"
            }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }
}

public enum StableDigest {
    public static func sha256Hex(_ data: Data) -> String {
        ASKSHA256.hexDigest(data)
    }
}
