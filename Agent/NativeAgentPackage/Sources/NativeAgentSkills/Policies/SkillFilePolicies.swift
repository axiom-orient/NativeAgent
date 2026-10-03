import Foundation
import NativeAgentDomain

#if canImport(Darwin)
import Darwin
#else
// Swift 6.2 Linux can attribute shared POSIX struct members to these C modules.
// Explicit imports preserve MemberImportVisibility in a cold module cache.
import CDispatch
import CoreFoundation
import Glibc
#endif

struct SkillFileImportPolicy {
    private enum NodeKind {
        case directory
        case regularFile
    }

    private struct TraversalBudget {
        var fileCount = 0
        var totalBytes = 0

        mutating func record(_ data: Data, path: String) throws {
            fileCount += 1
            guard fileCount <= SkillLocalFileLimits.maximumSkillFileCount else {
                throw AgentError.budgetExceeded(
                    "Skill directory exceeds the file-count limit at \(path); maximum is "
                        + "\(SkillLocalFileLimits.maximumSkillFileCount) files."
                )
            }
            guard
                data.count <= SkillLocalFileLimits.maximumSkillDirectoryBytes
                    - totalBytes
            else {
                throw AgentError.budgetExceeded(
                    "Skill directory exceeds the byte limit at \(path); maximum is "
                        + "\(SkillLocalFileLimits.maximumSkillDirectoryBytes) bytes."
                )
            }
            totalBytes += data.count
        }
    }

    let fileManager: FileManager
    let pathPolicy: SkillPathPolicy

    func createOrReplaceDirectory(_ url: URL) throws {
        try pathPolicy.validateUserSkillsURL(url)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func copySkillDirectory(from source: URL, to destination: URL) throws {
        let standardizedSource = source.standardizedFileURL
        let standardizedDestination = destination.standardizedFileURL
        try pathPolicy.validateUserSkillsURL(standardizedDestination)
        guard try nodeKind(at: standardizedSource) == .directory else {
            throw AgentError.invalidToolCall("Imported skill source must be a directory")
        }
        try fileManager.createDirectory(at: standardizedDestination, withIntermediateDirectories: true)
        var budget = TraversalBudget()
        try copySkillNode(
            from: standardizedSource,
            sourceRoot: standardizedSource,
            destinationRoot: standardizedDestination,
            depth: 0,
            budget: &budget
        )
    }

    func directoryDigest(at directoryURL: URL) throws -> String {
        let standardizedRoot = directoryURL.standardizedFileURL
        guard try nodeKind(at: standardizedRoot) == .directory else {
            throw AgentError.invalidToolCall("Skill digest source must be a directory")
        }

        var canonical = Data()
        var budget = TraversalBudget()
        try appendDirectoryDigestRecords(
            in: standardizedRoot,
            root: standardizedRoot,
            canonical: &canonical,
            depth: 0,
            budget: &budget
        )
        return SHA256HexDigest.digest(canonical)
    }

    private func appendDirectoryDigestRecords(
        in directoryURL: URL,
        root: URL,
        canonical: inout Data,
        depth: Int,
        budget: inout TraversalBudget
    ) throws {
        guard depth <= SkillLocalFileLimits.maximumSkillDirectoryDepth else {
            throw AgentError.budgetExceeded(
                "Skill directory depth exceeds " + "\(SkillLocalFileLimits.maximumSkillDirectoryDepth)."
            )
        }
        let children = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).sorted { left, right in
            left.lastPathComponent < right.lastPathComponent
        }
        guard children.count <= SkillLocalFileLimits.maximumDirectoryEntries else {
            throw AgentError.budgetExceeded(
                "Skill directory contains more than " + "\(SkillLocalFileLimits.maximumDirectoryEntries) entries."
            )
        }

        for child in children {
            let standardizedChild = child.standardizedFileURL
            let relativePath = standardizedChild.pathComponents
                .dropFirst(root.pathComponents.count)
                .joined(separator: "/")
            switch try nodeKind(at: standardizedChild) {
            case .directory:
                appendDigestRecord(marker: 0x44, path: relativePath, payload: Data(), to: &canonical)
                try appendDirectoryDigestRecords(
                    in: standardizedChild,
                    root: root,
                    canonical: &canonical,
                    depth: depth + 1,
                    budget: &budget
                )
            case .regularFile:
                let data = try SkillBoundedFileReader.read(
                    from: standardizedChild,
                    maximumByteCount: SkillLocalFileLimits.maximumSkillFileBytes,
                    label: "Skill file \(relativePath)"
                )
                try budget.record(data, path: relativePath)
                appendDigestRecord(
                    marker: 0x46,
                    path: relativePath,
                    payload: data,
                    to: &canonical
                )
            }
        }
    }

    private func appendDigestRecord(
        marker: UInt8,
        path: String,
        payload: Data,
        to canonical: inout Data
    ) {
        canonical.append(marker)
        appendLengthPrefixed(Data(path.utf8), to: &canonical)
        appendLengthPrefixed(payload, to: &canonical)
    }

    private func appendLengthPrefixed(_ value: Data, to output: inout Data) {
        var length = UInt64(value.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { bytes in
            output.append(contentsOf: bytes)
        }
        output.append(value)
    }

    private func copySkillNode(
        from current: URL,
        sourceRoot: URL,
        destinationRoot: URL,
        depth: Int,
        budget: inout TraversalBudget
    ) throws {
        guard depth <= SkillLocalFileLimits.maximumSkillDirectoryDepth else {
            throw AgentError.budgetExceeded(
                "Imported skill directory depth exceeds " + "\(SkillLocalFileLimits.maximumSkillDirectoryDepth)."
            )
        }
        let standardizedCurrent = current.standardizedFileURL
        switch try nodeKind(at: standardizedCurrent) {
        case .directory:
            if standardizedCurrent != sourceRoot {
                let target = try destinationRoot.appendingRelativePath(
                    from: sourceRoot, to: standardizedCurrent, isDirectory: true)
                try pathPolicy.validateUserSkillsURL(target)
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            }
            let children = try fileManager.contentsOfDirectory(
                at: standardizedCurrent, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            guard children.count <= SkillLocalFileLimits.maximumDirectoryEntries else {
                throw AgentError.budgetExceeded(
                    "Imported skill directory contains more than "
                        + "\(SkillLocalFileLimits.maximumDirectoryEntries) entries."
                )
            }
            for child in children {
                try copySkillNode(
                    from: child,
                    sourceRoot: sourceRoot,
                    destinationRoot: destinationRoot,
                    depth: depth + 1,
                    budget: &budget
                )
            }
        case .regularFile:
            let target = try destinationRoot.appendingRelativePath(
                from: sourceRoot, to: standardizedCurrent, isDirectory: false)
            try pathPolicy.validateUserSkillsURL(target)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try SkillBoundedFileReader.read(
                from: standardizedCurrent,
                maximumByteCount: SkillLocalFileLimits.maximumSkillFileBytes,
                label: "Imported skill file"
            )
            try budget.record(data, path: standardizedCurrent.lastPathComponent)
            try data.write(to: target, options: .atomic)
        }
    }

    /// Classification failure is not absence or a safe regular file. Both copy
    /// and digest use the same fail-closed policy; the reader validates the
    /// opened descriptor independently before reading any bytes.
    private func nodeKind(at url: URL) throws -> NodeKind {
        guard url.isFileURL, !url.path.utf8.contains(0) else {
            throw AgentError.invalidToolCall("Skill source must be a local file URL")
        }
        #if canImport(Darwin)
        var info = Darwin.stat()
        #else
        var info = Glibc.stat()
        #endif
        guard lstat(url.path, &info) == 0 else {
            let code = errno
            if code == ENOENT {
                throw AgentError.notFound("Skill source disappeared or does not exist: \(url.path)")
            }
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .regularFile
        case S_IFLNK:
            throw AgentError.invalidToolCall("Skill directories cannot contain symbolic links")
        default:
            throw AgentError.invalidToolCall("Skill source contains an unsupported filesystem node: \(url.path)")
        }
    }
}
