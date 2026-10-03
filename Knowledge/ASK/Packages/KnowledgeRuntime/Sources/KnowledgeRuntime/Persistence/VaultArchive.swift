import Foundation
import KnowledgeCore

private struct VaultExportManifest: Codable, Sendable, Equatable {
    var files: [String]
    var sha256: [String: String]
}

private enum ArchiveTool: String {
    case zip = "/usr/bin/zip"
    case unzip = "/usr/bin/unzip"
}

extension Vault {
    package func exportArchive(to outputURL: URL) throws {
        try withMaterializeLock {
            try bootstrap()
            _ = try rebuildUnlocked()
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            var manifest = VaultExportManifest(files: [], sha256: [:])
            var files: [(String, Data)] = []
            for relative in try allFiles().sorted() {
                let transient = try isTransientPath(relative)
                if relative.hasPrefix("mirror/") || transient { continue }
                let fileURL = root.appendingPathComponent(relative)
                let data = try Data(contentsOf: fileURL)
                files.append((relative, data))
                manifest.files.append(relative)
                manifest.sha256[relative] = ASKSHA256.hexDigest(data)
            }
            let manifestData = try CanonicalJSON.data(for: manifest) + Data([0x0a])
            files.append(("export-manifest.json", manifestData))
            try writeArchiveEntries(files, to: outputURL)
        }
    }

    package func importArchive(from archiveURL: URL) throws {
        try withImportLock {
            let parent = root.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let tmpRoot = parent.appendingPathComponent("ask-import-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
            do {
                try extractArchive(at: archiveURL, to: tmpRoot)
                try verifyImportManifest(at: tmpRoot)
                let imported = Vault(root: tmpRoot)
                _ = try imported.rebuildUnlocked()
                try replaceRootFromImport(tmpRoot)
                try removeArchivePathIfPresent(tmpRoot, label: "import temp root")
            } catch {
                let importError = error
                do {
                    try removeArchivePathIfPresent(tmpRoot, label: "import temp root")
                } catch {
                    throw ASKError.importIntegrity("import failed: \(importError); cleanup failed: \(error)")
                }
                throw importError
            }
        }
    }

    fileprivate func replaceRootFromImport(_ importedRoot: URL) throws {
        let fileManager = FileManager.default
        let parent = root.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let backupRoot = parent.appendingPathComponent("ask-backup-\(UUID().uuidString)", isDirectory: true)
        let rootExists = fileManager.fileExists(atPath: root.path)

        if rootExists {
            try fileManager.moveItem(at: root, to: backupRoot)
        }

        do {
            try fileManager.moveItem(at: importedRoot, to: root)
        } catch {
            let importError = error
            if rootExists {
                do {
                    try fileManager.moveItem(at: backupRoot, to: root)
                } catch {
                    throw ASKError.importIntegrity("failed to restore existing vault after import replacement failure: \(importError); restore error: \(error)")
                }
            }
            throw importError
        }

        try removeArchivePathIfPresent(backupRoot, label: "import backup root")
    }

    fileprivate func verifyImportManifest(at rootURL: URL) throws {
        let manifestURL = rootURL.appendingPathComponent("export-manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ASKError.importIntegrity("missing export manifest")
        }
        let manifest = try CanonicalJSON.load(VaultExportManifest.self, from: manifestURL)
        let actualFiles = try collectedFiles(in: rootURL)
            .filter { $0 != "export-manifest.json" }
        let expectedFileSet = Set(manifest.files)
        let actualFileSet = Set(actualFiles)
        if actualFileSet != expectedFileSet {
            let missing = Array(expectedFileSet.subtracting(actualFileSet)).sorted()
            let extra = Array(actualFileSet.subtracting(expectedFileSet)).sorted()
            throw ASKError.importIntegrity("manifest file set mismatch; missing=\(missing) extra=\(extra)")
        }
        for relative in manifest.files {
            let fileURL = rootURL.appendingPathComponent(relative)
            let digest = ASKSHA256.hexDigest(try Data(contentsOf: fileURL))
            if manifest.sha256[relative] != digest {
                throw ASKError.importIntegrity("hash mismatch for imported file `\(relative)`")
            }
        }
    }
}

package func removeArchivePathIfPresent(
    _ url: URL,
    label: String,
    remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do {
        try remove(url)
    } catch {
        throw ASKError.importIntegrity("archive cleanup failed for \(label): \(error)")
    }
}

private func collectedFiles(in root: URL) throws -> [String] {
    try persistenceRelativeFiles(in: root)
}

package func archiveEntryNames(at archiveURL: URL) throws -> [String] {
    try listedArchiveEntries(at: archiveURL)
}

package func writeArchiveEntries(_ entries: [(String, Data)], to outputURL: URL) throws {
    #if os(macOS) || os(Linux)
    if FileManager.default.fileExists(atPath: outputURL.path) {
        try FileManager.default.removeItem(at: outputURL)
    }
    let stagingRoot = outputURL.deletingLastPathComponent().appendingPathComponent("ask-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

    do {
        for (fileName, fileData) in entries {
            try ensureSafeArchiveEntryPath(fileName)
            let fileURL = stagingRoot.appendingPathComponent(fileName)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileData.write(to: fileURL, options: .atomic)
        }

        _ = try runArchiveTool(
            .zip,
            arguments: ["-q", "-r", outputURL.path, "."],
            currentDirectoryURL: stagingRoot,
            errorPrefix: "archive export failed"
        )
    } catch {
        let exportError = error
        do {
            try removeArchivePathIfPresent(stagingRoot, label: "export staging directory")
        } catch {
            throw ASKError.importIntegrity(
                "archive export failed: \(exportError); staging cleanup failed: \(error)"
            )
        }
        throw exportError
    }
    try removeArchivePathIfPresent(stagingRoot, label: "export staging directory")
    #else
    throw ASKError.platformUnavailable("archive export requires /usr/bin/zip and is unavailable on this platform")
    #endif
}

private func extractArchive(at archiveURL: URL, to destinationRoot: URL) throws {
    #if os(macOS) || os(Linux)
    let paths = try listedArchiveEntries(at: archiveURL)
    for path in paths {
        try ensureSafeArchiveEntryPath(path)
    }
    _ = try runArchiveTool(
        .unzip,
        arguments: ["-qq", "-n", archiveURL.path, "-d", destinationRoot.path],
        currentDirectoryURL: nil,
        errorPrefix: "archive import failed"
    )
    try validateExtractedArchiveTree(at: destinationRoot)
    #else
    throw ASKError.platformUnavailable("archive import requires /usr/bin/unzip and is unavailable on this platform")
    #endif
}

private func listedArchiveEntries(at archiveURL: URL) throws -> [String] {
    #if os(macOS) || os(Linux)
    let listing = try runArchiveTool(
        .unzip,
        arguments: ["-Z1", archiveURL.path],
        currentDirectoryURL: nil,
        errorPrefix: "archive listing failed"
    )
    return listing
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    #else
    throw ASKError.platformUnavailable("archive listing requires /usr/bin/unzip and is unavailable on this platform")
    #endif
}

private func ensureSafeArchiveEntryPath(_ path: String) throws {
    let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
    if normalized.isEmpty { return }
    if normalized.hasPrefix("/") || normalized.split(separator: "/").contains("..") {
        throw ASKError.importIntegrity("unsafe archive path `\(path)`")
    }
}

/// The archive tool preserves symbolic links. Validate the extracted staging tree before
/// manifest verification or vault replacement so no link can become part of the vault root.
private func validateExtractedArchiveTree(at root: URL) throws {
    let fileManager = FileManager.default
    var pendingDirectories = [root]

    while let directory = pendingDirectories.popLast() {
        let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
            throw ASKError.importIntegrity("archive staging root contains a symbolic link")
        }

        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        for child in children {
            let values = try child.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                throw ASKError.importIntegrity("archive contains a symbolic link entry `\(child.path)`")
            }
            if values.isDirectory == true {
                pendingDirectories.append(child)
            } else if values.isRegularFile != true {
                throw ASKError.importIntegrity("archive contains a non-regular entry `\(child.path)`")
            }
        }
    }
}

#if os(macOS) || os(Linux)
private func runArchiveTool(
    _ tool: ArchiveTool,
    arguments: [String],
    currentDirectoryURL: URL?,
    errorPrefix: String
) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool.rawValue)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectoryURL ?? URL(fileURLWithPath: "/", isDirectory: true)
    // Drain one shared pipe before waiting. Waiting first can deadlock when either
    // child stream fills its OS pipe buffer (notably for a large `unzip -Z1` list).
    let outputPipe = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = outputPipe
    process.standardError = outputPipe
    try process.run()
    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let diagnostics = String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw ASKError.importIntegrity(diagnostics.isEmpty ? errorPrefix : "\(errorPrefix): \(diagnostics)")
    }
    return String(decoding: outputData, as: UTF8.self)
}
#endif
