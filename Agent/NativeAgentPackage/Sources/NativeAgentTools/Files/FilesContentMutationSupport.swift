import Foundation
import NativeAgentDomain

actor FilesMutationCoordinator {
    let fileManager = FileManager()

    func writeText(
        request: FilesWriteTextRequest,
        pathResolver: FilesSandboxPathResolver,
        maximumWriteBytes: Int,
        requireExpectedSHA256ForOverwrite: Bool
    ) throws -> FilesWriteTextResult {
        let absoluteURL = try filesPreflight(operation: "files.writeText.preflight", path: request.path) {
            try pathResolver.resolve(path: request.path, fileManager: fileManager)
        }
        guard let data = request.content.data(using: .utf8, allowLossyConversion: false) else {
            throw ToolPreflightFailure(
                code: .invalidInput,
                operation: "files.writeText.preflight",
                cause: "Unable to encode content as UTF-8.",
                context: ["path": request.path]
            )
        }
        guard data.count <= maximumWriteBytes else {
            throw ToolPreflightFailure(
                code: .temporaryFailure,
                operation: "files.writeText.preflight",
                cause: "File write exceeds budget of \(maximumWriteBytes) bytes.",
                context: ["path": request.path]
            )
        }

        let existingData: Data?
        if fileManager.fileExists(atPath: absoluteURL.path) {
            existingData = try filesPreflight(operation: "files.writeText.preflight", path: request.path) {
                try ToolPackBoundedFileReader.read(
                    from: absoluteURL,
                    maximumByteCount: maximumWriteBytes,
                    label: "Existing file"
                )
            }
        } else {
            existingData = nil
        }

        let previousSHA256 = existingData.map(SHA256HexDigest.digest)
        if let expectedSHA256 = request.expectedSHA256 {
            guard let previousSHA256 else {
                throw ToolPreflightFailure(
                    code: .conflict,
                    operation: "files.writeText.preflight",
                    cause: "Expected file no longer exists.",
                    context: ["path": request.path, "expectedSHA256": expectedSHA256]
                )
            }
            guard previousSHA256 == expectedSHA256 else {
                throw filesDigestConflict(
                    operation: "files.writeText.preflight",
                    path: request.path,
                    expected: expectedSHA256,
                    actual: previousSHA256
                )
            }
        }

        if let existingData {
            if existingData == data {
                return FilesWriteTextResult(
                    byteCount: data.count,
                    action: .skippedIdentical,
                    sha256: SHA256HexDigest.digest(data),
                    previousSHA256: previousSHA256
                )
            }
            guard request.overwrite else {
                throw ToolPreflightFailure(
                    code: .permissionDenied,
                    operation: "files.writeText.preflight",
                    cause: "Refusing to overwrite existing file without overwrite=true.",
                    context: ["path": request.path]
                )
            }
            if requireExpectedSHA256ForOverwrite, request.expectedSHA256 == nil {
                throw ToolPreflightFailure(
                    code: .conflict,
                    operation: "files.writeText.preflight",
                    cause: "Overwriting an existing file requires expectedSHA256 from files.readText.",
                    context: ["path": request.path]
                )
            }
        }

        do {
            try fileManager.createDirectory(
                at: absoluteURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: absoluteURL, options: .atomic)
        } catch {
            throw EffectFailure.outcomeUnknown(
                operation: "files.writeText.commit",
                cause: error.localizedDescription,
                context: ["path": request.path]
            )
        }
        let verifiedSHA256 = try verifyCommittedBytes(
            expected: data,
            at: absoluteURL,
            maximumByteCount: maximumWriteBytes,
            operation: "files.writeText.verify",
            path: request.path
        )
        return FilesWriteTextResult(
            byteCount: data.count,
            action: .written,
            sha256: verifiedSHA256,
            previousSHA256: previousSHA256
        )
    }

    func replaceText(
        request: FilesReplaceTextRequest,
        pathResolver: FilesSandboxPathResolver,
        maximumMutationBytes: Int
    ) throws -> FilesReplaceTextResult {
        let absoluteURL = try filesPreflight(operation: "files.replaceText.preflight", path: request.path) {
            try pathResolver.resolve(path: request.path, fileManager: fileManager)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: absoluteURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue == false else {
            throw ToolPreflightFailure(
                code: .notFound,
                operation: "files.replaceText.preflight",
                cause: "File not found.",
                context: ["path": request.path]
            )
        }

        let existingData = try filesPreflight(operation: "files.replaceText.preflight", path: request.path) {
            try ToolPackBoundedFileReader.read(
                from: absoluteURL,
                maximumByteCount: maximumMutationBytes,
                label: "File replacement input"
            )
        }
        let actualSHA256 = SHA256HexDigest.digest(existingData)
        guard actualSHA256 == request.expectedSHA256 else {
            throw filesDigestConflict(
                operation: "files.replaceText.preflight",
                path: request.path,
                expected: request.expectedSHA256,
                actual: actualSHA256
            )
        }
        guard let existing = String(data: existingData, encoding: .utf8) else {
            throw ToolPreflightFailure(
                code: .invalidInput,
                operation: "files.replaceText.preflight",
                cause: "File is not valid UTF-8 text.",
                context: ["path": request.path]
            )
        }

        let occurrenceCount = existing.components(separatedBy: request.old).count - 1
        guard occurrenceCount == 1 else {
            throw ToolPreflightFailure(
                code: .conflict,
                operation: "files.replaceText.preflight",
                cause: "Expected exactly one replacement occurrence, found \(occurrenceCount).",
                context: ["path": request.path]
            )
        }
        let replacement = existing.replacingOccurrences(of: request.old, with: request.new)
        guard let replacementData = replacement.data(using: .utf8, allowLossyConversion: false) else {
            throw ToolPreflightFailure(
                code: .invalidInput,
                operation: "files.replaceText.preflight",
                cause: "Unable to encode replacement as UTF-8.",
                context: ["path": request.path]
            )
        }
        guard replacementData.count <= maximumMutationBytes else {
            throw ToolPreflightFailure(
                code: .temporaryFailure,
                operation: "files.replaceText.preflight",
                cause: "Replacement output exceeds budget of \(maximumMutationBytes) bytes.",
                context: ["path": request.path]
            )
        }

        do {
            try replacementData.write(to: absoluteURL, options: .atomic)
        } catch {
            throw EffectFailure.outcomeUnknown(
                operation: "files.replaceText.commit",
                cause: error.localizedDescription,
                context: ["path": request.path]
            )
        }
        let verifiedSHA256 = try verifyCommittedBytes(
            expected: replacementData,
            at: absoluteURL,
            maximumByteCount: maximumMutationBytes,
            operation: "files.replaceText.verify",
            path: request.path
        )
        return FilesReplaceTextResult(
            byteCount: replacementData.count,
            previousSHA256: actualSHA256,
            sha256: verifiedSHA256
        )
    }

    private func verifyCommittedBytes(
        expected: Data,
        at url: URL,
        maximumByteCount: Int,
        operation: String,
        path: String
    ) throws -> String {
        let observed: Data
        do {
            observed = try ToolPackBoundedFileReader.read(
                from: url,
                maximumByteCount: maximumByteCount,
                label: "Mutation verification"
            )
        } catch {
            throw EffectFailure.outcomeUnknown(
                operation: operation,
                cause: error.localizedDescription,
                context: ["path": path]
            )
        }
        guard observed == expected else {
            throw EffectFailure.outcomeUnknown(
                operation: operation,
                cause: "Read-back bytes differ from the committed bytes.",
                context: [
                    "path": path,
                    "expectedSHA256": SHA256HexDigest.digest(expected),
                    "observedSHA256": SHA256HexDigest.digest(observed)
                ]
            )
        }
        return SHA256HexDigest.digest(observed)
    }
}

func filesPreflight<T>(
    operation: String,
    path: String,
    _ body: () throws -> T
) throws -> T {
    do {
        return try body()
    } catch let failure as ToolPreflightFailure {
        throw failure
    } catch let error as AgentError {
        throw ToolPreflightFailure(
            code: error.defaultToolFailureCode,
            operation: operation,
            cause: error.localizedDescription,
            context: ["path": path]
        )
    } catch {
        throw ToolPreflightFailure(
            code: .temporaryFailure,
            operation: operation,
            cause: error.localizedDescription,
            context: ["path": path]
        )
    }
}

func filesDigestConflict(
    operation: String,
    path: String,
    expected: String,
    actual: String
) -> ToolPreflightFailure {
    ToolPreflightFailure(
        code: .conflict,
        operation: operation,
        cause: "Content changed before mutation.",
        context: [
            "path": path,
            "expectedSHA256": expected,
            "actualSHA256": actual
        ]
    )
}

struct FilesReplaceTextRequest: Sendable, Equatable {
    let path: String
    let expectedSHA256: String
    let old: String
    let new: String

    init(arguments: JSONValue) throws {
        path = try arguments.stringField("path")
        expectedSHA256 = try FilesSHA256.validate(try arguments.stringField("expectedSHA256"))
        old = try arguments.stringField("old")
        new = try arguments.stringField("new")
        guard old.isEmpty == false else {
            throw AgentError.invalidToolCall("old must not be empty")
        }
    }
}

struct FilesReplaceTextResult: Sendable, Equatable {
    let byteCount: Int
    let previousSHA256: String
    let sha256: String
}

enum FilesSHA256 {
    static func validate(_ value: String) throws -> String {
        guard value.count == 64,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw AgentError.invalidToolCall(
                "expectedSHA256 must be 64 lowercase hexadecimal characters"
            )
        }
        return value
    }
}
