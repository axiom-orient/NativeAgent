import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ASKMarkdownWikiLayout: Codable, Hashable, Sendable {
    public let rawDirectory: String
    public let wikiDirectory: String
    public let schemaDirectory: String
    public let logsDirectory: String
}

public struct ASKWikiEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let filename: String
    public let title: String
    public let type: String?
    public let status: String?
    public let date: String?
    public let url: String?
    public let icon: String?
    public let archived: Bool
    public let favorite: Bool
    public let snippet: String
    public let wordCount: UInt32
    public let fileSize: UInt64
    public let modifiedAt: UInt64?
    public let createdAt: UInt64?
    public let outgoingLinks: [String]
    public let backlinks: [String]
    public let relationships: [String: [String]]
    public let properties: [String: String]
    public let folderPath: String
    public let category: String
}

public struct ASKWikiProjection: Codable, Sendable {
    public let layout: ASKMarkdownWikiLayout
    public let entries: [ASKWikiEntry]
    public let typeCounts: [String: Int]
    public let folderCounts: [String: Int]
}

public struct ASKMarkdownWikiPage: Codable, Hashable, Sendable {
    public let path: String
    public let title: String
    public let bodyPreview: String
    public let outgoingLinks: [String]
    public let backlinks: [String]
}

public struct ASKMarkdownWikiSnapshot: Codable, Sendable {
    public let layout: ASKMarkdownWikiLayout
    public let rawSources: [ASKMarkdownWikiPage]
    public let wikiPages: [ASKMarkdownWikiPage]
    public let schemaFiles: [ASKMarkdownWikiPage]
    public let logFiles: [ASKMarkdownWikiPage]
}

public enum ASKMarkdownWikiError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidPath(String)
    case outsideRoot(String)
    case outsideWikiWriteBoundary(String)
    case markdownWriteRequired(String)
    case pageAlreadyExists(String)
    case missingFile(String)
    case unreadableRoot(String)
    case unreadableFile(String)
    case rollbackFailed(path: String, original: String, rollback: String)

    public var description: String {
        switch self {
        case .invalidPath(let path): "invalid Markdown Wiki path: \(path)"
        case .outsideRoot(let path): "Markdown Wiki path resolves outside the root: \(path)"
        case .outsideWikiWriteBoundary(let path): "wiki mutation is limited to wiki/: \(path)"
        case .markdownWriteRequired(let path): "wiki mutation requires a Markdown file: \(path)"
        case .pageAlreadyExists(let path): "Markdown Wiki page already exists: \(path)"
        case .missingFile(let path): "Markdown Wiki file does not exist: \(path)"
        case .unreadableRoot(let path): "Markdown Wiki root is unreadable: \(path)"
        case .unreadableFile(let path): "Markdown Wiki file is not valid UTF-8 text: \(path)"
        case .rollbackFailed(let path, let original, let rollback):
            "Markdown Wiki mutation failed for \(path): \(original); rollback failed: \(rollback)"
        }
    }
}

public struct ASKMarkdownWikiService: Sendable {
    private let mutationHook: (@Sendable () -> Void)?
    private let postWriteHook: (@Sendable () -> Void)?

    public init() {
        mutationHook = nil
        postWriteHook = nil
    }

    init(
        mutationHook: @escaping @Sendable () -> Void,
        postWriteHook: (@Sendable () -> Void)? = nil
    ) {
        self.mutationHook = mutationHook
        self.postWriteHook = postWriteHook
    }

    public func bootstrap(root: URL) throws -> ASKMarkdownWikiSnapshot {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileSystem = try ASKManagedWikiFileSystem(root: root)
        try fileSystem.validateManagedPaths(
            ASKMarkdownWikiAccessPolicy.appReadDirectories + [
                "wiki/index.md",
                "schema/ASK_LLM_WIKI.md",
                "logs/log.md",
            ]
        )
        for directory in ASKMarkdownWikiAccessPolicy.appReadDirectories {
            try fileSystem.ensureDirectory(path: directory)
        }
        try fileSystem.createIfMissing(path: "wiki/index.md", data: Data("# Index\n\nTDos project wiki.\n".utf8))
        try fileSystem.createIfMissing(path: "schema/ASK_LLM_WIKI.md", data: Data("# ASK LLM Wiki\n\nRead raw, wiki, and schema. Write only wiki Markdown.\n".utf8))
        try fileSystem.createIfMissing(path: "logs/log.md", data: Data("# Log\n\n".utf8))
        return try snapshot(root: root)
    }

    public func snapshot(root: URL) throws -> ASKMarkdownWikiSnapshot {
        let pages = try scanPages(root: root)
        return ASKMarkdownWikiSnapshot(
            layout: layout(),
            rawSources: pages.filter { $0.path.hasPrefix("raw/") },
            wikiPages: pages.filter { $0.path.hasPrefix("wiki/") },
            schemaFiles: pages.filter { $0.path.hasPrefix("schema/") },
            logFiles: pages.filter { $0.path.hasPrefix("logs/") }
        )
    }

    public func uiProjection(root: URL) throws -> ASKWikiProjection {
        let entries = try scanEntries(root: root)
        return ASKWikiProjection(
            layout: layout(),
            entries: entries,
            typeCounts: Dictionary(grouping: entries.compactMap(\.type), by: { $0 }).mapValues(\.count),
            folderCounts: Dictionary(grouping: entries.map(\.folderPath), by: { $0 }).mapValues(\.count)
        )
    }

    public func readText(root: URL, relativePath: String, allowLogs: Bool = true) throws -> String {
        let path = try ASKMarkdownWikiAccessPolicy.authorizeAppRead(relativePath, allowLogs: allowLogs)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ASKMarkdownWikiError.missingFile(path)
        }
        do {
            let fileSystem = try ASKManagedWikiFileSystem(root: root)
            guard let data = try fileSystem.readDataIfPresent(path: path) else {
                throw ASKMarkdownWikiError.missingFile(path)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw ASKMarkdownWikiError.unreadableFile(path)
            }
            return text
        } catch let error as ASKMarkdownWikiError {
            throw error
        } catch {
            throw ASKMarkdownWikiError.unreadableFile(path)
        }
    }

    public func writeWikiPage(root: URL, relativePath: String, content: String) throws -> ASKMarkdownWikiSnapshot {
        try mutateWikiPage(root: root, relativePath: relativePath, content: content, requireAbsent: false)
    }

    public func createWikiPage(root: URL, relativePath: String, content: String) throws -> ASKMarkdownWikiSnapshot {
        try mutateWikiPage(root: root, relativePath: relativePath, content: content, requireAbsent: true)
    }

    private func mutateWikiPage(
        root: URL,
        relativePath: String,
        content: String,
        requireAbsent: Bool
    ) throws -> ASKMarkdownWikiSnapshot {
        let path = try ASKMarkdownWikiAccessPolicy.authorizeWikiMarkdownMutation(relativePath)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileSystem = try ASKManagedWikiFileSystem(root: root)
        let mutation = try fileSystem.openMutation(path: path)
        mutationHook?()
        let previous = try mutation.readDataIfPresent()
        if requireAbsent, previous != nil {
            throw ASKMarkdownWikiError.pageAlreadyExists(path)
        }
        do {
            let written = Data(content.utf8)
            try mutation.writeAtomically(written, requireAbsent: requireAbsent)
            postWriteHook?()
            return try snapshot(root: root)
        } catch {
            let original = error
            do {
                try mutation.restore(previous, expected: Data(content.utf8))
            } catch {
                throw ASKMarkdownWikiError.rollbackFailed(
                    path: path,
                    original: String(describing: original),
                    rollback: String(describing: error)
                )
            }
            throw original
        }
    }

    private func scanPages(root: URL) throws -> [ASKMarkdownWikiPage] {
        try scanEntries(root: root).map {
            ASKMarkdownWikiPage(path: $0.path, title: $0.title, bodyPreview: $0.snippet, outgoingLinks: [], backlinks: [])
        }
    }

    private func scanEntries(root: URL) throws -> [ASKWikiEntry] {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ASKMarkdownWikiError.unreadableRoot(root.path)
        }
        var entries: [ASKWikiEntry] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey])
            guard values.isRegularFile == true else { continue }
            let path = relativePath(root: resolvedRoot, url: url)
            guard ASKMarkdownWikiAccessPolicy.appReadDirectories.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            let safeURL = try resolvedURL(root: resolvedRoot, relativePath: path)
            let text: String
            do {
                text = try String(contentsOf: safeURL, encoding: .utf8)
            } catch {
                throw ASKMarkdownWikiError.unreadableFile(path)
            }
            let filename = url.lastPathComponent
            let folder = String(path.split(separator: "/").dropLast().joined(separator: "/"))
            entries.append(ASKWikiEntry(
                path: path,
                filename: filename,
                title: ASKMarkdownSupport.title(from: text, fallback: url.deletingPathExtension().lastPathComponent),
                type: nil,
                status: nil,
                date: nil,
                url: nil,
                icon: nil,
                archived: false,
                favorite: false,
                snippet: ASKMarkdownSupport.snippet(from: text),
                wordCount: UInt32(text.split { $0.isWhitespace }.count),
                fileSize: UInt64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate.map { UInt64($0.timeIntervalSince1970) },
                createdAt: values.creationDate.map { UInt64($0.timeIntervalSince1970) },
                outgoingLinks: [],
                backlinks: [],
                relationships: [:],
                properties: [:],
                folderPath: folder,
                category: path.split(separator: "/").first.map(String.init) ?? ""
            ))
        }
        return entries.sorted { $0.path < $1.path }
    }

    private func resolvedURL(root: URL, relativePath: String) throws -> URL {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let lexicalCandidate = root.appendingPathComponent(relativePath).standardizedFileURL

        var pathComponent = root.standardizedFileURL
        for component in relativePath.split(separator: "/") {
            pathComponent.appendPathComponent(String(component))
            if try isSymbolicLink(at: pathComponent) {
                throw ASKMarkdownWikiError.outsideRoot(relativePath)
            }
        }

        var existingAncestor = lexicalCandidate
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: existingAncestor.path) {
            let parent = existingAncestor.deletingLastPathComponent()
            guard parent.path != existingAncestor.path else {
                throw ASKMarkdownWikiError.outsideRoot(relativePath)
            }
            missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor = parent
        }

        var candidate = existingAncestor.resolvingSymlinksInPath()
        for component in missingComponents {
            candidate.appendPathComponent(component)
        }
        candidate = candidate.standardizedFileURL

        let rootPrefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else {
            throw ASKMarkdownWikiError.outsideRoot(relativePath)
        }
        return candidate
    }

    private func isSymbolicLink(at url: URL) throws -> Bool {
        if FileManager.default.fileExists(atPath: url.path) {
            return try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
        }
        do {
            _ = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            return true
        } catch {
            let nsError = error as NSError
            let isMissing = (nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.fileReadNoSuchFile.rawValue)
                || (nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT)
            if isMissing { return false }
            throw error
        }
    }

    private func layout() -> ASKMarkdownWikiLayout {
        ASKMarkdownWikiLayout(rawDirectory: "raw", wikiDirectory: "wiki", schemaDirectory: "schema", logsDirectory: "logs")
    }

    private func relativePath(root: URL, url: URL) -> String {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }
}

enum ASKMarkdownWikiAccessPolicy {
    static let appReadDirectories = ["raw", "wiki", "schema", "logs"]

    static func authorizeAppRead(_ path: String, allowLogs: Bool) throws -> String {
        let clean = try normalize(path)
        let allowed = allowLogs ? appReadDirectories : ["raw", "wiki", "schema"]
        guard allowed.contains(where: { clean == $0 || clean.hasPrefix($0 + "/") }) else {
            throw ASKMarkdownWikiError.invalidPath(path)
        }
        return clean
    }

    static func authorizeWikiMarkdownMutation(_ path: String) throws -> String {
        let clean = try normalize(path)
        guard clean.hasPrefix("wiki/") else {
            throw ASKMarkdownWikiError.outsideWikiWriteBoundary(path)
        }
        guard clean.hasSuffix(".md") || clean.hasSuffix(".markdown") else {
            throw ASKMarkdownWikiError.markdownWriteRequired(path)
        }
        return clean
    }

    private static func normalize(_ path: String) throws -> String {
        do {
            return try ASKMarkdownPathPolicy.normalize(path)
        } catch {
            throw ASKMarkdownWikiError.invalidPath(path)
        }
    }
}

private final class ASKManagedWikiFileSystem {
    private let rootFD: Int32

    init(root: URL) throws {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let fd = resolvedRoot.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard fd >= 0 else {
            throw askPOSIXError(errno, path: resolvedRoot.path)
        }
        rootFD = fd
    }

    deinit {
        close(rootFD)
    }

    func ensureDirectory(path: String) throws {
        let fd = try openDirectory(components: pathComponents(path), create: true, path: path)
        try askCloseDescriptor(fd, path: path)
    }

    func validateManagedPaths(_ paths: [String]) throws {
        for path in paths {
            let components = pathComponents(path)
            guard let leaf = components.last else { continue }
            do {
                let parentFD = try openDirectory(
                    components: Array(components.dropLast()),
                    create: false,
                    path: path
                )
                try askWithClosedDescriptor(parentFD, path: path) {
                    let fd = leaf.withCString {
                        openat(parentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                    }
                    if fd >= 0 {
                        try askCloseDescriptor(fd, path: path)
                    } else {
                        let code = errno
                        if code == ELOOP { throw ASKMarkdownWikiError.outsideRoot(path) }
                        if code != ENOENT { throw askPOSIXError(code, path: path) }
                    }
                }
            } catch let error as NSError where askPOSIXCode(error) == ENOENT {
                continue
            }
        }
    }

    func createIfMissing(path: String, data: Data) throws {
        let mutation = try openMutation(path: path)
        do {
            try mutation.writeAtomically(data, requireAbsent: true)
        } catch let error as ASKMarkdownWikiError {
            if case .pageAlreadyExists = error { return }
            throw error
        }
    }

    func openMutation(path: String) throws -> ASKManagedWikiMutation {
        let components = pathComponents(path)
        guard let leaf = components.last else {
            throw ASKMarkdownWikiError.invalidPath(path)
        }
        let parent = Array(components.dropLast())
        let parentFD = try openDirectory(components: parent, create: true, path: path)
        return ASKManagedWikiMutation(parentFD: parentFD, leaf: leaf, path: path)
    }

    func readDataIfPresent(path: String) throws -> Data? {
        let components = pathComponents(path)
        guard let leaf = components.last else {
            throw ASKMarkdownWikiError.invalidPath(path)
        }
        let parentFD: Int32
        do {
            parentFD = try openDirectory(components: Array(components.dropLast()), create: false, path: path)
        } catch let error as NSError where askPOSIXCode(error) == ENOENT {
            return nil
        }
        return try askWithClosedDescriptor(parentFD, path: path) {
            let fd = leaf.withCString {
                openat(parentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard fd >= 0 else {
                let code = errno
                if code == ENOENT { return nil }
                if code == ELOOP { throw ASKMarkdownWikiError.outsideRoot(path) }
                throw askPOSIXError(code, path: path)
            }
            return try askWithClosedDescriptor(fd, path: path) {
                try askReadAll(fd: fd, path: path)
            }
        }
    }

    private func openDirectory(components: [String], create: Bool, path: String) throws -> Int32 {
        if components.isEmpty {
            let duplicate = dup(rootFD)
            guard duplicate >= 0 else { throw askPOSIXError(errno, path: path) }
            return duplicate
        }

        var currentFD = rootFD
        var ownsCurrent = false
        for component in components {
            let nextFD: Int32
            do {
                nextFD = try openDirectoryComponent(
                    parentFD: currentFD,
                    component: component,
                    create: create,
                    path: path
                )
            } catch {
                let operation = error
                if ownsCurrent {
                    do {
                        try askCloseDescriptor(currentFD, path: path)
                    } catch let cleanup {
                        throw askOperationCleanupError(
                            operation: operation,
                            cleanup: cleanup,
                            path: path
                        )
                    }
                }
                throw operation
            }
            if ownsCurrent {
                do {
                    try askCloseDescriptor(currentFD, path: path)
                } catch let cleanup {
                    do {
                        try askCloseDescriptor(nextFD, path: path)
                    } catch let nextCleanup {
                        throw askOperationCleanupError(
                            operation: cleanup,
                            cleanup: nextCleanup,
                            path: path
                        )
                    }
                    throw cleanup
                }
            }
            currentFD = nextFD
            ownsCurrent = true
        }
        return currentFD
    }

    private func openDirectoryComponent(parentFD: Int32, component: String, create: Bool, path: String) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        var fd = component.withCString { openat(parentFD, $0, flags) }
        if fd >= 0 { return fd }

        var code = errno
        if code == ELOOP { throw ASKMarkdownWikiError.outsideRoot(path) }
        if code == ENOTDIR, try isSymbolicLink(parentFD: parentFD, component: component, path: path) {
            throw ASKMarkdownWikiError.outsideRoot(path)
        }
        guard create, code == ENOENT else {
            throw askPOSIXError(code, path: path)
        }

        let mkdirResult = component.withCString { mkdirat(parentFD, $0, mode_t(0o755)) }
        if mkdirResult != 0 {
            code = errno
            if code != EEXIST { throw askPOSIXError(code, path: path) }
        }

        fd = component.withCString { openat(parentFD, $0, flags) }
        guard fd >= 0 else {
            code = errno
            if code == ELOOP { throw ASKMarkdownWikiError.outsideRoot(path) }
            if code == ENOTDIR, try isSymbolicLink(parentFD: parentFD, component: component, path: path) {
                throw ASKMarkdownWikiError.outsideRoot(path)
            }
            throw askPOSIXError(code, path: path)
        }
        return fd
    }

    private func isSymbolicLink(parentFD: Int32, component: String, path: String) throws -> Bool {
        var info = stat()
        let result = component.withCString {
            fstatat(parentFD, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 {
            return (info.st_mode & S_IFMT) == S_IFLNK
        }
        let code = errno
        if code == ENOENT { return false }
        throw askPOSIXError(code, path: path)
    }

    private func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }
}

private final class ASKManagedWikiMutation {
    private let parentFD: Int32
    private let leaf: String
    private let path: String

    init(parentFD: Int32, leaf: String, path: String) {
        self.parentFD = parentFD
        self.leaf = leaf
        self.path = path
    }

    deinit {
        close(parentFD)
    }

    func readDataIfPresent() throws -> Data? {
        let fd = leaf.withCString {
            openat(parentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT { return nil }
            if code == ELOOP { throw ASKMarkdownWikiError.outsideRoot(path) }
            throw askPOSIXError(code, path: path)
        }
        return try askWithClosedDescriptor(fd, path: path) {
            try askReadAll(fd: fd, path: path)
        }
    }

    func writeAtomically(_ data: Data, requireAbsent: Bool) throws {
        if requireAbsent {
            let existing = leaf.withCString {
                openat(parentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            if existing >= 0 {
                let operation = ASKMarkdownWikiError.pageAlreadyExists(path)
                do {
                    try askCloseDescriptor(existing, path: path)
                } catch let cleanup {
                    throw askOperationCleanupError(
                        operation: operation,
                        cleanup: cleanup,
                        path: path
                    )
                }
                throw operation
            }
            let code = errno
            if code == ELOOP { throw ASKMarkdownWikiError.outsideRoot(path) }
            if code != ENOENT { throw askPOSIXError(code, path: path) }
        }

        let temporary = ".ask-\(UUID().uuidString).tmp"
        let temporaryFD = temporary.withCString {
            openat(
                parentFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o644)
            )
        }
        guard temporaryFD >= 0 else {
            throw askPOSIXError(errno, path: path)
        }

        var closed = false
        do {
            try askWriteAll(fd: temporaryFD, data: data, path: path)
            guard close(temporaryFD) == 0 else {
                closed = true
                throw askPOSIXError(errno, path: path)
            }
            closed = true

            if requireAbsent {
                let linked = temporary.withCString { temporaryName in
                    leaf.withCString { leafName in
                        linkat(parentFD, temporaryName, parentFD, leafName, 0)
                    }
                }
                guard linked == 0 else {
                    let code = errno
                    if code == EEXIST { throw ASKMarkdownWikiError.pageAlreadyExists(path) }
                    throw askPOSIXError(code, path: path)
                }
                guard temporary.withCString({ unlinkat(parentFD, $0, 0) }) == 0 else {
                    throw askPOSIXError(errno, path: path)
                }
            } else {
                guard temporary.withCString({ tempName in
                    leaf.withCString { leafName in
                        renameat(parentFD, tempName, parentFD, leafName)
                    }
                }) == 0 else {
                    throw askPOSIXError(errno, path: path)
                }
            }
        } catch {
            let operation = error
            var cleanupMessages: [String] = []
            var cleanupCode: Int32 = EIO
            if !closed {
                do {
                    try askCloseDescriptor(temporaryFD, path: path)
                } catch let cleanup {
                    cleanupMessages.append(cleanup.localizedDescription)
                    cleanupCode = Int32((cleanup as NSError).code)
                }
            }
            let unlinkResult = temporary.withCString { unlinkat(parentFD, $0, 0) }
            if unlinkResult != 0 {
                let code = errno
                if code != ENOENT {
                    cleanupCode = cleanupMessages.isEmpty ? code : cleanupCode
                    cleanupMessages.append(askPOSIXError(code, path: path).localizedDescription)
                }
            }
            if !cleanupMessages.isEmpty {
                let cleanup = NSError(
                    domain: "com.axiomorient.nativeagent.markdown-wiki.cleanup",
                    code: Int(cleanupCode),
                    userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: cleanupMessages.joined(separator: "; ")]
                )
                throw askOperationCleanupError(operation: operation, cleanup: cleanup, path: path)
            }
            throw operation
        }
    }

    func restore(_ data: Data?, expected: Data) throws {
        guard let current = try readDataIfPresent(), current == expected else {
            return
        }
        if let data {
            try writeAtomically(data, requireAbsent: false)
            return
        }
        let result = leaf.withCString { unlinkat(parentFD, $0, 0) }
        guard result == 0 || errno == ENOENT else {
            throw askPOSIXError(errno, path: path)
        }
    }
}

private func askPOSIXCode(_ error: NSError) -> Int32? {
    guard error.domain == NSPOSIXErrorDomain else { return nil }
    return Int32(error.code)
}

private func askPOSIXError(_ code: Int32, path: String) -> NSError {
    NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(code),
        userInfo: [NSFilePathErrorKey: path]
    )
}

private func askCloseDescriptor(_ descriptor: Int32, path: String) throws {
    guard close(descriptor) == 0 else {
        let code = errno
        throw askPOSIXError(code, path: path)
    }
}

private func askOperationCleanupError(
    operation: any Error,
    cleanup: any Error,
    path: String
) -> NSError {
    let cleanupError = cleanup as NSError
    return NSError(
        domain: "com.axiomorient.nativeagent.markdown-wiki",
        code: cleanupError.code,
        userInfo: [
            NSFilePathErrorKey: path,
            NSUnderlyingErrorKey: operation,
            "cleanupError": cleanup.localizedDescription,
        ]
    )
}

private func askWithClosedDescriptor<T>(
    _ descriptor: Int32,
    path: String,
    _ body: () throws -> T
) throws -> T {
    let result: Result<T, any Error>
    do {
        result = .success(try body())
    } catch {
        result = .failure(error)
    }
    do {
        try askCloseDescriptor(descriptor, path: path)
    } catch let cleanup {
        switch result {
        case .success:
            throw cleanup
        case .failure(let operation):
            throw askOperationCleanupError(operation: operation, cleanup: cleanup, path: path)
        }
    }
    return try result.get()
}

private func askReadAll(fd: Int32, path: String) throws -> Data {
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
            read(fd, rawBuffer.baseAddress, rawBuffer.count)
        }
        if count == 0 { return output }
        guard count > 0 else { throw askPOSIXError(errno, path: path) }
        output.append(contentsOf: buffer.prefix(count))
    }
}

private func askWriteAll(fd: Int32, data: Data, path: String) throws {
    try data.withUnsafeBytes { rawData in
        guard let baseAddress = rawData.baseAddress else { return }
        var offset = 0
        while offset < rawData.count {
            let count = write(fd, baseAddress.advanced(by: offset), rawData.count - offset)
            guard count > 0 else { throw askPOSIXError(errno, path: path) }
            offset += count
        }
    }
}
