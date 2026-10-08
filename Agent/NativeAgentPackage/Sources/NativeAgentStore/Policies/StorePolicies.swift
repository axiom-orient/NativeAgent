import Foundation
import NativeAgentDomain

struct ValidatedSessionID: Sendable, Hashable {
    let rawValue: String

    init(_ rawValue: String) throws {
        guard rawValue.isEmpty == false, rawValue.count <= 128 else {
            throw AgentError.persistenceFailure("Invalid session ID.")
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let isValid = rawValue.unicodeScalars.allSatisfy { allowed.contains($0) }
        guard isValid else {
            throw AgentError.persistenceFailure("Invalid session ID.")
        }

        self.rawValue = rawValue
    }
}

struct ValidatedArtifactID: Sendable, Hashable {
    let rawValue: String

    init(_ rawValue: String) throws {
        guard rawValue.isEmpty == false, rawValue.utf8.count <= 128 else {
            throw AgentError.persistenceFailure("Invalid artifact ID.")
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard rawValue.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw AgentError.persistenceFailure("Invalid artifact ID.")
        }
        self.rawValue = rawValue
    }
}

struct ValidatedEffectScope: Sendable, Hashable {
    let rawValue: String

    init(_ rawValue: String) throws {
        guard rawValue.isEmpty == false, rawValue.count <= 128 else {
            throw AgentError.persistenceFailure("Invalid effect scope.")
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        let isValid = rawValue.unicodeScalars.allSatisfy { allowed.contains($0) }
        guard isValid else {
            throw AgentError.persistenceFailure("Invalid effect scope.")
        }

        self.rawValue = rawValue
    }
}

struct ValidatedEffectKey: Sendable, Hashable {
    let rawValue: String

    init(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else {
            throw AgentError.persistenceFailure("Invalid effect key.")
        }
        self.rawValue = value
    }
}

struct ArtifactStoragePlan: Sendable, Equatable {
    let artifactID: String
    let filename: String
    let relativePath: String
    let absoluteURL: URL

    init(
        sessionID: ValidatedSessionID,
        preferredFilename: String,
        rootURL: URL,
        artifactID: String
    ) {
        self.artifactID = artifactID

        let safeFilename = preferredFilename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFilename = safeFilename.isEmpty ? "artifact.bin" : safeFilename

        self.filename = "\(artifactID)-\(normalizedFilename)"
        self.relativePath = "sessions/\(sessionID.rawValue)/artifacts/\(filename)"
        self.absoluteURL = rootURL
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
    }
}

struct StoreSandboxGuard {
    let rootURL: URL
    let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func validateFileURL(_ url: URL) throws -> URL {
        let candidate = url.standardizedFileURL
        try validateURLIsInsideSandbox(candidate)
        try ensureNoSymlinks(onPathFromRootTo: candidate)
        return candidate
    }

    private func validateURLIsInsideSandbox(_ url: URL) throws {
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let path = url.path
        guard path == rootURL.path || path.hasPrefix(rootPath) else {
            throw AgentError.pathOutsideSandbox("Path escapes sandbox root.")
        }
    }

    private func ensureNoSymlinks(onPathFromRootTo target: URL) throws {
        if try isSymbolicLink(at: rootURL) {
            throw AgentError.pathOutsideSandbox("Sandbox root cannot be a symlink.")
        }

        let relativeComponents = target.pathComponents.dropFirst(rootURL.pathComponents.count)
        var current = rootURL

        for (index, component) in relativeComponents.enumerated() {
            let isFinal = index == relativeComponents.count - 1
            current.appendPathComponent(component, isDirectory: !isFinal)

            if try isSymbolicLink(at: current) {
                throw AgentError.pathOutsideSandbox("Symlink traversal is not allowed in the sandbox store.")
            }
        }
    }

    private func isSymbolicLink(at url: URL) throws -> Bool {
        do {
            return try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
        } catch {
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
