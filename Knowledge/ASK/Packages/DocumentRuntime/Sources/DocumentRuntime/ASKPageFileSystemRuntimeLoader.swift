import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import DocumentCore

public struct ASKPageFileSystemRuntimeLoader: Sendable, ASKPageRuntimePackageLoader, ASKPageDocumentLoader {
    public let planner: ASKPageRuntimePlanner
    private let readHook: (@Sendable (String, URL) -> Void)?

    public init(planner: ASKPageRuntimePlanner = .init()) {
        self.planner = planner
        self.readHook = nil
    }

    init(readHook: @escaping @Sendable (String, URL) -> Void) {
        self.planner = .init()
        self.readHook = readHook
    }

    public func loadPackage(from location: ASKPageDocumentLocation) async throws -> ASKPageRuntimePackage {
        let manifest = try loadManifest(from: location)
        guard let selection = planner.selectArtifact(in: manifest) else {
            throw ASKPageRuntimeError.noSelectableArtifact(planner.preferredArtifactOrder())
        }

        let document = try loadCanonicalDocument(manifest: manifest, rootURL: location.rootURL)
        let selectedArtifact = try loadSelectedArtifact(selection: selection, rootURL: location.rootURL)
        return ASKPageRuntimePackage(document: document, selection: selection, selectedArtifact: selectedArtifact)
    }

    public func loadDocument(from location: ASKPageDocumentLocation) async throws -> ASKPageDocument {
        try await loadPackage(from: location).document
    }

    public func loadManifest(from location: ASKPageDocumentLocation) throws -> ASKPageRuntimeManifest {
        let manifestURL = location.rootURL
            .appendingPathComponent(ASKPageRuntimeManifest.defaultFilename, isDirectory: false)
            .standardizedFileURL
        let manifestPath = manifestURL.askPageFileSystemPath
        let manifest: ASKPageRuntimeManifest
        do {
            manifest = try loadJSON(
                relativePath: ASKPageRuntimeManifest.defaultFilename,
                rootURL: location.rootURL,
                readError: ASKPageRuntimeError.failedToReadData,
                decodeError: ASKPageRuntimeError.failedToDecodeManifest
            )
        } catch let error as ASKPageRuntimeError {
            if case .fileNotFound = error {
                throw ASKPageRuntimeError.missingManifest(manifestPath)
            }
            throw error
        }

        guard manifest.version == ASKPageRuntimeManifest.currentVersion else {
            throw ASKPageRuntimeError.unsupportedManifestVersion(manifest.version)
        }
        return manifest
    }

    private func loadCanonicalDocument(manifest: ASKPageRuntimeManifest, rootURL: URL) throws -> ASKPageDocument {
        if let documentJSONPath = manifest.documentJSONPath, !documentJSONPath.isEmpty {
            return try loadJSON(
                relativePath: documentJSONPath,
                rootURL: rootURL,
                readError: ASKPageRuntimeError.failedToReadData,
                decodeError: ASKPageRuntimeError.failedToDecodeDocument
            )
        }

        guard let markdown = manifest.markdown else {
            throw ASKPageRuntimeError.missingCanonicalDocument
        }

        let markdownText = try readUTF8Text(relativePath: markdown.path, rootURL: rootURL)
        return ASKPageMarkdownCompiler().compile(
            markdown: markdownText,
            documentID: markdown.documentID,
            sourceID: markdown.sourceID,
            title: markdown.title,
            authoritativeMarkdownPath: markdown.authoritativeMarkdownPath ?? markdown.path
        )
    }

    private func loadSelectedArtifact(selection: ASKPageRuntimeSelection, rootURL: URL) throws -> ASKPageRuntimeArtifactPayload {
        guard let selectedPath = selection.selectedPath else {
            throw ASKPageRuntimeError.noSelectableArtifact(selection.attemptedKinds)
        }

        switch selection.selectedKind {
        case .scene:
            let scene: ASKCanvasPage = try loadJSON(
                relativePath: selectedPath,
                rootURL: rootURL,
                readError: ASKPageRuntimeError.failedToReadData,
                decodeError: ASKPageRuntimeError.failedToDecodeScene
            )
            return .scene(scene)
        case .hybridTemplate:
            return .hybridTemplate(try readUTF8Text(relativePath: selectedPath, rootURL: rootURL))
        case .fullHTML:
            return .fullHTML(try readUTF8Text(relativePath: selectedPath, rootURL: rootURL))
        case .markdown:
            return .markdown(try readUTF8Text(relativePath: selectedPath, rootURL: rootURL))
        }
    }

    private func loadJSON<Value: Decodable>(
        relativePath: String,
        rootURL: URL,
        readError: (String) -> ASKPageRuntimeError,
        decodeError: (String) -> ASKPageRuntimeError
    ) throws -> Value {
        let data = try readData(relativePath: relativePath, rootURL: rootURL, readError: readError)
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw decodeError(relativePath)
        }
    }

    private func readData(
        relativePath: String,
        rootURL: URL,
        readError: (String) -> ASKPageRuntimeError
    ) throws -> Data {
        do {
            return try ASKContainedRuntimeReader(
                rootURL: rootURL,
                readHook: readHook
            ).readData(relativePath: relativePath)
        } catch let error as ASKPageRuntimeError {
            throw error
        } catch {
            throw readError(relativePath)
        }
    }

    private func readUTF8Text(relativePath: String, rootURL: URL) throws -> String {
        let data = try readData(
            relativePath: relativePath,
            rootURL: rootURL,
            readError: ASKPageRuntimeError.failedToReadText
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw ASKPageRuntimeError.failedToReadText(relativePath)
        }
        return text
    }
}

private final class ASKContainedRuntimeReader {
    private let rootURL: URL
    private let readHook: (@Sendable (String, URL) -> Void)?

    init(rootURL: URL, readHook: (@Sendable (String, URL) -> Void)?) {
        self.rootURL = rootURL
        self.readHook = readHook
    }

    func readData(relativePath: String) throws -> Data {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ASKPageRuntimeError.fileNotFound(relativePath)
        }

        let canonicalRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalCandidate = URL(fileURLWithPath: trimmed, relativeTo: canonicalRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidatePath = canonicalCandidate.askPageFileSystemPath
        let rawRootPath = canonicalRoot.askPageFileSystemPath
        let rootPath = rawRootPath.count > 1 && rawRootPath.hasSuffix("/")
            ? String(rawRootPath.dropLast())
            : rawRootPath
        guard let components = relativeComponents(candidatePath: candidatePath, rootPath: rootPath) else {
            throw ASKPageRuntimeError.filePathEscapesRoot(relativePath)
        }

        let rootFD = canonicalRoot.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard rootFD >= 0 else {
            let code = errno
            if code == ENOENT { throw ASKPageRuntimeError.fileNotFound(relativePath) }
            throw askRuntimePOSIXError(code, path: relativePath)
        }
        return try askRuntimeWithCheckedClose(rootFD, path: relativePath) {
            let leaf: String
            let parentComponents: [String]
            if let last = components.last {
                leaf = last
                parentComponents = Array(components.dropLast())
            } else {
                throw ASKPageRuntimeError.fileNotFound(relativePath)
            }

            let parentFD = try openParentDirectory(
                rootFD: rootFD,
                components: parentComponents,
                path: relativePath
            )
            return try askRuntimeWithCheckedClose(parentFD, path: relativePath) {
                readHook?(relativePath, canonicalRoot)

                let fileFD = leaf.withCString {
                    openat(parentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard fileFD >= 0 else {
                    let code = errno
                    if code == ELOOP { throw ASKPageRuntimeError.filePathEscapesRoot(relativePath) }
                    if code == ENOENT || code == ENOTDIR {
                        throw ASKPageRuntimeError.fileNotFound(relativePath)
                    }
                    throw askRuntimePOSIXError(code, path: relativePath)
                }
                return try askRuntimeWithCheckedClose(fileFD, path: relativePath) {
                    try readAll(fileFD: fileFD, path: relativePath)
                }
            }
        }
    }

    private func relativeComponents(candidatePath: String, rootPath: String) -> [String]? {
        if rootPath == "/" {
            guard candidatePath.hasPrefix("/") else { return nil }
            return candidatePath.dropFirst().split(separator: "/").map(String.init)
        }
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        guard candidatePath != rootPath else { return [] }
        return candidatePath.dropFirst(rootPath.count + 1).split(separator: "/").map(String.init)
    }

    private func openParentDirectory(rootFD: Int32, components: [String], path: String) throws -> Int32 {
        var currentFD = rootFD
        var ownsCurrent = false
        for component in components {
            let nextFD = component.withCString {
                openat(currentFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard nextFD >= 0 else {
                let code = errno
                let primaryError: any Error
                if code == ELOOP {
                    primaryError = ASKPageRuntimeError.filePathEscapesRoot(path)
                } else if code == ENOENT || code == ENOTDIR {
                    primaryError = ASKPageRuntimeError.fileNotFound(path)
                } else {
                    primaryError = askRuntimePOSIXError(code, path: path)
                }
                if ownsCurrent, let closeError = askRuntimeCloseDescriptor(currentFD, path: path) {
                    throw askRuntimeOperationCleanupError(
                        operation: primaryError,
                        cleanupErrors: [closeError],
                        path: path
                    )
                }
                throw primaryError
            }
            if ownsCurrent, let closeError = askRuntimeCloseDescriptor(currentFD, path: path) {
                if let nextCloseError = askRuntimeCloseDescriptor(nextFD, path: path) {
                    throw askRuntimeOperationCleanupError(
                        operation: closeError,
                        cleanupErrors: [nextCloseError],
                        path: path
                    )
                }
                throw closeError
            }
            currentFD = nextFD
            ownsCurrent = true
        }
        if ownsCurrent { return currentFD }
        let duplicate = dup(rootFD)
        guard duplicate >= 0 else { throw askRuntimePOSIXError(errno, path: path) }
        return duplicate
    }

    private func readAll(fileFD: Int32, path: String) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                read(fileFD, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { return data }
            guard count > 0 else { throw askRuntimePOSIXError(errno, path: path) }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}

private func askRuntimeCloseDescriptor(_ descriptor: Int32, path: String) -> NSError? {
    guard close(descriptor) != 0 else { return nil }
    let code = errno
    return askRuntimePOSIXError(code, path: path)
}

private func askRuntimeOperationCleanupError(
    operation: any Error,
    cleanupErrors: [any Error],
    path: String
) -> NSError {
    let cleanupCode: Int
    if let firstCleanupError = cleanupErrors.first {
        cleanupCode = (firstCleanupError as NSError).code
    } else {
        cleanupCode = 1
    }
    return NSError(
        domain: "com.axiomorient.nativeagent.document-runtime",
        code: cleanupCode,
        userInfo: [
            NSFilePathErrorKey: path,
            NSUnderlyingErrorKey: operation,
            "cleanupError": cleanupErrors.map { $0.localizedDescription }.joined(separator: "; "),
        ]
    )
}

private func askRuntimeWithCheckedClose<T>(
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

    guard close(descriptor) == 0 else {
        let closeError = askRuntimePOSIXError(errno, path: path)
        switch result {
        case .success:
            throw closeError
        case .failure(let error):
            throw NSError(
                domain: "com.axiomorient.nativeagent.document-runtime",
                code: closeError.code,
                userInfo: [
                    NSFilePathErrorKey: path,
                    NSUnderlyingErrorKey: error,
                    "cleanupError": closeError,
                ]
            )
        }
    }
    return try result.get()
}

private func askRuntimePOSIXError(_ code: Int32, path: String) -> NSError {
    NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(code),
        userInfo: [NSFilePathErrorKey: path]
    )
}
