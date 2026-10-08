import Foundation
import NativeAgentDomain

struct FilesSandboxPathResolver: Sendable {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    func resolve(path: String, fileManager: FileManager = .default) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try ensureRootIsNotSymlink(fileManager: fileManager)
            return rootURL
        }
        guard trimmed.hasPrefix("/") == false else {
            throw AgentError.pathOutsideSandbox("Absolute paths are not allowed.")
        }

        let candidate = rootURL
            .appendingPathComponent(trimmed, isDirectory: false)
            .standardizedFileURL
        return try validateResolvedURL(candidate, fileManager: fileManager)
    }

    func relativePath(for url: URL) -> String {
        relativePathIfContained(for: url) ?? "<outside sandbox>"
    }

    private func relativePathIfContained(for url: URL) -> String? {
        let standardizedRoot = rootURL.path
        let standardizedURL = url.standardizedFileURL.path
        if standardizedURL == standardizedRoot {
            return ""
        }
        let prefix = standardizedRoot.hasSuffix("/") ? standardizedRoot : standardizedRoot + "/"
        if standardizedURL.hasPrefix(prefix) {
            return String(standardizedURL.dropFirst(prefix.count))
        }
        return nil
    }

    private func validateResolvedURL(_ url: URL, fileManager: FileManager) throws -> URL {
        try ensureRootIsNotSymlink(fileManager: fileManager)

        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let candidate = url.standardizedFileURL
        let candidatePath = candidate.path

        guard candidatePath == rootURL.path || candidatePath.hasPrefix(rootPath) else {
            throw AgentError.pathOutsideSandbox("Path escapes sandbox root: \(relativePath(for: candidate))")
        }

        try ensureNoSymlinks(onPathFromRootTo: candidate, fileManager: fileManager)
        return candidate
    }

    private func ensureNoSymlinks(onPathFromRootTo target: URL, fileManager: FileManager) throws {
        let relativeComponents = target.pathComponents.dropFirst(rootURL.pathComponents.count)
        var current = rootURL

        for (index, component) in relativeComponents.enumerated() {
            let isFinal = index == relativeComponents.count - 1
            current.appendPathComponent(component, isDirectory: !isFinal)

            // Symlink checks are best-effort within the host-owned app sandbox; callers
            // must keep the sandbox root private to avoid path-swap races.
            if try isSymbolicLink(at: current, fileManager: fileManager) {
                throw AgentError.pathOutsideSandbox("Symlink traversal is not allowed.")
            }
        }
    }

    private func ensureRootIsNotSymlink(fileManager: FileManager) throws {
        if try isSymbolicLink(at: rootURL, fileManager: fileManager) {
            throw AgentError.pathOutsideSandbox("Root sandbox path cannot be a symlink.")
        }
    }

    private func isSymbolicLink(at url: URL, fileManager: FileManager) throws -> Bool {
        do {
            return try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
        } catch {
            // Foundation may report a missing path for a dangling link. Probe the
            // link itself before treating that error as an absent path.
            guard fileManager.fileExists(atPath: url.path) == false else {
                throw error
            }
            do {
                _ = try fileManager.destinationOfSymbolicLink(atPath: url.path)
                return true
            } catch let linkError {
                let nsError = linkError as NSError
                guard nsError.domain == NSCocoaErrorDomain,
                      (nsError.code == CocoaError.Code.fileNoSuchFile.rawValue
                        || nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue) else {
                    throw linkError
                }
                return false
            }
        }
    }
}

struct FilesSearchTraversal: Sendable {
    let resolver: FilesSandboxPathResolver
    let maxVisitedNodes: Int
    let instructionCatalog: InstructionDocumentCatalog

    func collectMatches(
        in directoryURL: URL,
        query: String,
        limit: Int,
        cursor: String?,
        includeInstructionFiles: Bool,
        fileManager: FileManager = .default
    ) throws -> FilesSearchPage {
        let rootPath = resolver.relativePath(for: directoryURL)
        var stack = try traversalStack(
            cursor: cursor,
            rootPath: rootPath,
            query: query,
            includeInstructionFiles: includeInstructionFiles,
            fileManager: fileManager
        )
        var visitedNodes = 0
        var matches: [JSONValue] = []
        matches.reserveCapacity(limit)
        let classifier = FilesInstructionClassifier(resolver: resolver, catalog: instructionCatalog)

        while stack.isEmpty == false {
            if Task.isCancelled { throw CancellationError() }
            if visitedNodes >= maxVisitedNodes {
                return FilesSearchPage(
                    matches: matches,
                    nextCursor: try encodeCursor(
                        stack: stack,
                        rootPath: rootPath,
                        query: query,
                        includeInstructionFiles: includeInstructionFiles
                    )
                )
            }

            if stack[stack.count - 1].nextIndex >= stack[stack.count - 1].entries.count {
                stack.removeLast()
                continue
            }

            let frameIndex = stack.count - 1
            let url = stack[frameIndex].entries[stack[frameIndex].nextIndex]
            stack[frameIndex].nextIndex += 1
            visitedNodes += 1

            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true { continue }

            let relativePath = resolver.relativePath(for: url)
            let instructionDescriptor = classifier.descriptor(forRelativePath: relativePath)
            let isHiddenInstruction = instructionDescriptor != nil && includeInstructionFiles == false

            if isHiddenInstruction == false,
               relativePath.lowercased().contains(query) {
                matches.append(
                    makeMatchEntry(
                        url: url,
                        values: values,
                        relativePath: relativePath,
                        instructionDescriptor: instructionDescriptor
                    )
                )
            }

            if values.isDirectory == true {
                stack.append(try runtimeFrame(path: relativePath, nextIndex: 0, fileManager: fileManager))
            }

            if matches.count >= limit {
                return FilesSearchPage(
                    matches: matches,
                    nextCursor: try encodeCursor(
                        stack: stack,
                        rootPath: rootPath,
                        query: query,
                        includeInstructionFiles: includeInstructionFiles
                    )
                )
            }
        }

        return FilesSearchPage(matches: matches, nextCursor: nil)
    }

    private struct CursorFrame: Codable {
        let path: String
        let nextIndex: Int
    }

    private struct SearchCursor: Codable {
        let version: Int
        let rootPath: String
        let query: String
        let includeInstructionFiles: Bool
        let stack: [CursorFrame]
    }

    private struct RuntimeFrame {
        let path: String
        let entries: [URL]
        var nextIndex: Int
    }

    private func traversalStack(
        cursor: String?,
        rootPath: String,
        query: String,
        includeInstructionFiles: Bool,
        fileManager: FileManager
    ) throws -> [RuntimeFrame] {
        guard let cursor else {
            return [try runtimeFrame(path: rootPath, nextIndex: 0, fileManager: fileManager)]
        }
        guard cursor.utf8.count <= FilesSearchRequest.maximumCursorBytes,
              let data = Data(base64Encoded: cursor),
              let value = try? JSONDecoder().decode(SearchCursor.self, from: data),
              value.version == 1,
              value.rootPath == rootPath,
              value.query == query,
              value.includeInstructionFiles == includeInstructionFiles,
              value.stack.isEmpty == false else {
            throw AgentError.invalidToolCall("Files search cursor does not match this search.")
        }
        var stack: [RuntimeFrame] = []
        stack.reserveCapacity(value.stack.count)
        for cursorFrame in value.stack {
            let frame = try runtimeFrame(
                path: cursorFrame.path,
                nextIndex: cursorFrame.nextIndex,
                fileManager: fileManager
            )
            if let parent = stack.last {
                guard parent.nextIndex > 0 else {
                    throw AgentError.invalidToolCall("Files search cursor has an invalid traversal chain.")
                }
                let enteredDirectory = parent.entries[parent.nextIndex - 1]
                let values = try enteredDirectory.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard values.isDirectory == true,
                      values.isSymbolicLink != true,
                      resolver.relativePath(for: enteredDirectory) == frame.path else {
                    throw AgentError.invalidToolCall("Files search cursor leaves its requested subtree.")
                }
            } else if frame.path != rootPath {
                throw AgentError.invalidToolCall("Files search cursor leaves its requested subtree.")
            }
            stack.append(frame)
        }
        return stack
    }

    private func runtimeFrame(
        path: String,
        nextIndex: Int,
        fileManager: FileManager
    ) throws -> RuntimeFrame {
        let directoryURL = try resolver.resolve(path: path, fileManager: fileManager)
        let entries = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        .sorted { $0.path < $1.path }
        guard nextIndex >= 0, nextIndex <= entries.count else {
            throw AgentError.invalidToolCall("Files search cursor no longer matches the directory tree.")
        }
        return RuntimeFrame(path: path, entries: entries, nextIndex: nextIndex)
    }

    private func encodeCursor(
        stack: [RuntimeFrame],
        rootPath: String,
        query: String,
        includeInstructionFiles: Bool
    ) throws -> String? {
        var remainingStack = stack
        while let last = remainingStack.last,
              last.nextIndex >= last.entries.count {
            remainingStack.removeLast()
        }
        guard remainingStack.isEmpty == false else { return nil }
        let cursor = SearchCursor(
            version: 1,
            rootPath: rootPath,
            query: query,
            includeInstructionFiles: includeInstructionFiles,
            stack: remainingStack.map { CursorFrame(path: $0.path, nextIndex: $0.nextIndex) }
        )
        let encoded = try JSONEncoder().encode(cursor).base64EncodedString()
        guard encoded.utf8.count <= FilesSearchRequest.maximumCursorBytes else {
            throw AgentError.budgetExceeded("Files search cursor exceeded its safety bound.")
        }
        return encoded
    }

    private func makeMatchEntry(
        url: URL,
        values: URLResourceValues,
        relativePath: String,
        instructionDescriptor: InstructionDocumentDescriptor?
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "relativePath": .string(relativePath),
            "name": .string(url.lastPathComponent),
            "isDirectory": .bool(values.isDirectory ?? false),
            "isRegularFile": .bool(values.isRegularFile ?? false),
            "isSymbolicLink": .bool(values.isSymbolicLink ?? false),
            "isInstructionDocument": .bool(instructionDescriptor != nil),
            "byteCount": values.fileSize.map { .integer(Int64($0)) } ?? .null
        ]

        if let instructionDescriptor {
            object["instructionScope"] = .string(instructionDescriptor.scope.rawValue)
        }

        return .object(object)
    }
}
