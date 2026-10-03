import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import KnowledgeCore

extension Vault {
    package func bootstrap() throws {
        let directories = [
            "raw/evidence",
            "raw/assets",
            "records/representations",
            "wiki/wiki",
            "wiki/sources",
            "wiki/entities",
            "wiki/topics",
            "wiki/current",
            "wiki/queries",
            "wiki/playbook",
            "wiki/casebook",
            "schema",
            "mirror",
            ".ask/journal/patches",
            ".ask/journal/events",
            ".ask/generation",
        ]
        for relative in directories {
            try createDirectory(relative)
        }
        let schemaURL = root.appendingPathComponent("schema/AGENTS.md")
        if !FileManager.default.fileExists(atPath: schemaURL.path) {
            try writeTextFile(
                schemaURL,
                content: """
                # Agent-Synced Knowledge schema notes

                This vault is compiler-owned. Evidence and authority are canonical; projections and mirror are derived.
                """
            )
        }
    }

    package func withMaterializeLock<T>(_ body: () throws -> T) throws -> T {
        try bootstrap()
        return try withFileLock(at: materializeLockURL(), label: "materialize", body)
    }

    package func withImportLock<T>(_ body: () throws -> T) throws -> T {
        let parent = root.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let lockURL = parent.appendingPathComponent(".ask-import-\(root.lastPathComponent).lock")
        return try withFileLock(at: lockURL, label: "import", body)
    }

    package func withFileLock<T>(at lockURL: URL, label: String, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw ASKError.apply("unable to open \(label) lock")
        }
        defer { close(fd) }
        if flock(fd, LOCK_EX) != 0 {
            throw ASKError.apply("unable to acquire \(label) lock")
        }
        defer { _ = flock(fd, LOCK_UN) }

        let pidString = "\(getpid())"
        _ = ftruncate(fd, 0)
        _ = lseek(fd, 0, SEEK_SET)
        pidString.withCString { cString in
            _ = write(fd, cString, strlen(cString))
        }
        let result = try body()
        _ = ftruncate(fd, 0)
        return result
    }

    package func allFiles() throws -> [String] {
        try persistenceRelativeFiles(in: root)
    }

    /// Drops every derived output. Materialization writes incrementally instead,
    /// so this is the explicit reset used when derived state must not survive.
    package func clearGeneratedOutputs() throws {
        for relative in DerivedOutputPlan.ownedDirectories {
            let url = root.appendingPathComponent(relative, isDirectory: true)
            try removeItemIfPresent(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }

        for relative in DerivedOutputPlan.ownedFiles + ["mirror/knowledge.sqlite", ".ask/generation/canonical.json"] {
            try removeGeneratedFile(relative)
        }
    }

    package func removeGeneratedFile(_ relativePath: String) throws {
        try removeItemIfPresent(at: try validatedVaultURL(root.appendingPathComponent(relativePath)))
    }

    private func removeItemIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
