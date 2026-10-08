import Foundation
import KnowledgeCore

/// Byte-exact description of every derived file materialization owns.
///
/// Materialization used to delete each generated subtree and rewrite every file
/// on every apply, which made a single apply cost O(total records) in atomic
/// writes and the whole journal O(n²). The plan is built in memory first so the
/// filesystem only sees the difference against what is already on disk.
package struct DerivedOutputPlan {
    /// Subtrees fully owned by materialization: anything inside them that the
    /// plan does not list is stale and gets removed.
    ///
    /// `records/representations` is deliberately absent. Representations are
    /// written through the public API rather than derived from the journal, so
    /// owning that directory meant every apply deleted them.
    package static let ownedDirectories = [
        "wiki/wiki",
        "wiki/sources",
        "wiki/entities",
        "wiki/topics",
        "wiki/current",
        "wiki/queries",
        "wiki/playbook",
        "wiki/casebook",
    ]

    /// Individual owned files that live outside the owned subtrees.
    package static let ownedFiles = [
        "index.md",
        "log.md",
    ]

    private(set) var files: [String: Data] = [:]

    package init() {}

    package mutating func putJSON(_ relativePath: String, payload: some Encodable) throws {
        try put(relativePath, bytes: CanonicalJSON.data(for: payload) + Data([0x0a]))
    }

    package mutating func putText(_ relativePath: String, content: String) throws {
        let encoded = content + (content.hasSuffix("\n") ? "" : "\n")
        guard let data = encoded.data(using: .utf8) else {
            throw ASKError.validation("failed to encode UTF-8 text content")
        }
        try put(relativePath, bytes: data)
    }

    private mutating func put(_ relativePath: String, bytes: Data) throws {
        try ASKValidation.requireRelativePath("relative_path", relativePath)
        let isOwned = DerivedOutputPlan.ownedFiles.contains(relativePath)
            || DerivedOutputPlan.ownedDirectories.contains { relativePath.hasPrefix($0 + "/") }
        guard isOwned else {
            throw ASKError.apply("derived output `\(relativePath)` is outside materialization-owned paths")
        }
        if files[relativePath] != nil {
            throw ASKError.apply("derived output collision at `\(relativePath)`")
        }
        files[relativePath] = bytes
    }
}

extension Vault {
    /// Writes only what differs from disk and removes what the plan no longer owns.
    package func syncDerivedOutputs(_ plan: DerivedOutputPlan) throws {
        let fileManager = FileManager.default

        var owned = Set<String>()
        for directory in DerivedOutputPlan.ownedDirectories {
            let url = try validatedVaultURL(root.appendingPathComponent(directory, isDirectory: true))
            for relative in try existingFiles(under: url, prefix: directory) {
                owned.insert(relative)
            }
        }
        for relative in DerivedOutputPlan.ownedFiles {
            let url = try validatedVaultURL(root.appendingPathComponent(relative))
            if fileManager.fileExists(atPath: url.path) {
                owned.insert(relative)
            }
        }

        // Validate every target before the first effect, including existing
        // parent symlinks. Lexical ownership alone does not confine filesystem I/O.
        for relative in owned.union(plan.files.keys) {
            _ = try validatedVaultURL(root.appendingPathComponent(relative))
        }
        for directory in DerivedOutputPlan.ownedDirectories {
            try createDirectory(directory)
        }
        for relative in owned.subtracting(plan.files.keys).sorted() {
            try removeGeneratedFile(relative)
        }

        for relative in plan.files.keys.sorted() {
            guard let desired = plan.files[relative] else { continue }
            let url = try validatedVaultURL(root.appendingPathComponent(relative))
            if owned.contains(relative) {
                do {
                    if try Data(contentsOf: url) == desired {
                        continue
                    }
                } catch let error as CocoaError
                    where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                    // The output disappeared after discovery; the normal write
                    // path below recreates the owned file.
                } catch {
                    throw ASKError.apply(
                        "unable to inspect existing derived output `\(relative)`: \(error)"
                    )
                }
            }
            try writeBytesFile(url, content: desired)
        }

        // The clear-and-rewrite path never left empty record subdirectories
        // behind; pruning keeps the materialized tree identical to a full rebuild.
        for directory in DerivedOutputPlan.ownedDirectories {
            let url = root.appendingPathComponent(directory, isDirectory: true)
            _ = try pruneEmptyDirectories(at: url, removeSelf: false)
        }
    }

    private func existingFiles(under url: URL, prefix: String) throws -> [String] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return []
        }
        var output: [String] = []
        let basePath = url.standardizedFileURL.path
        for case let child as URL in enumerator {
            guard child.lastPathComponent != ".DS_Store" else { continue }
            let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw ASKError.validation("symbolic link in materialization-owned directory")
            }
            guard values.isRegularFile == true else { continue }
            let childPath = child.standardizedFileURL.path
            guard childPath.hasPrefix(basePath + "/") else { continue }
            output.append(prefix + "/" + String(childPath.dropFirst(basePath.count + 1)))
        }
        return output
    }

    @discardableResult
    private func pruneEmptyDirectories(at url: URL, removeSelf: Bool) throws -> Bool {
        let fileManager = FileManager.default
        _ = try validatedVaultURL(url)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        var isEmpty = true
        for child in try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw ASKError.validation("symbolic link in materialization-owned directory")
            }
            if values.isDirectory == true {
                if try pruneEmptyDirectories(at: child, removeSelf: true) { continue }
                isEmpty = false
            } else if child.lastPathComponent == ".DS_Store" {
                continue
            } else {
                isEmpty = false
            }
        }
        if isEmpty && removeSelf {
            try fileManager.removeItem(at: url)
            return true
        }
        return isEmpty
    }
}
