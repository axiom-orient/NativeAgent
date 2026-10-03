import Foundation
import KnowledgeCore

public struct StagedCapturePaths: Sendable, Equatable {
    public var stagingRoot: URL
    public var rawPath: URL
    public var manifestPath: URL
    public var collectedPath: URL
    public var notePath: URL

    public init(stagingRoot: URL, rawPath: URL, manifestPath: URL, collectedPath: URL, notePath: URL) {
        self.stagingRoot = stagingRoot
        self.rawPath = rawPath
        self.manifestPath = manifestPath
        self.collectedPath = collectedPath
        self.notePath = notePath
    }
}

public enum CaptureStager {
    public static func stage(_ bundle: WebCaptureBundle, using provider: some CaptureStagingRootProviding) throws -> StagedCapturePaths {
        try stage(bundle, at: provider.stagingRoot())
    }

    public static func stage(_ bundle: WebCaptureBundle, at stagingRoot: URL) throws -> StagedCapturePaths {
        try bundle.manifest.validate()
        try bundle.collectedSource.validate()
        try validateBundleParity(bundle)

        let paths = stagingPaths(for: bundle, stagingRoot: stagingRoot)
        try validateStagingPaths(paths)

        let transactionRoot = stagingRoot.deletingLastPathComponent()
            .appendingPathComponent(".ask-capture-transaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: transactionRoot, withIntermediateDirectories: true)
        let transactionPaths = stagingPaths(for: bundle, stagingRoot: transactionRoot)
        do {
            try writeStagedCapture(bundle, to: transactionPaths)
            try commitStagedCapture(from: transactionPaths, to: paths, transactionRoot: transactionRoot)
            try FileManager.default.removeItem(at: transactionRoot)
        } catch let primaryError {
            do {
                try FileManager.default.removeItem(at: transactionRoot)
            } catch let cleanupError {
                throw ASKError.apply(
                    "capture staging failed: \(primaryError); transaction cleanup also failed: \(cleanupError)"
                )
            }
            throw primaryError
        }
        return paths
    }
}

private func stagingPaths(for bundle: WebCaptureBundle, stagingRoot: URL) -> StagedCapturePaths {
    let rawPath = stagingRoot.appendingPathComponent(bundle.manifest.rawRelpath)
    let captureDirectory = stagingRoot.appendingPathComponent(".ask/collector/web/\(bundle.manifest.sourceID)", isDirectory: true)
    let manifestPath = captureDirectory.appendingPathComponent("capture_manifest.json")
    let collectedPath = captureDirectory.appendingPathComponent("collected_source.json")
    let notePath = captureDirectory.appendingPathComponent("curated_note.md")

    return StagedCapturePaths(
        stagingRoot: stagingRoot,
        rawPath: rawPath,
        manifestPath: manifestPath,
        collectedPath: collectedPath,
        notePath: notePath
    )
}

private func writeStagedCapture(_ bundle: WebCaptureBundle, to paths: StagedCapturePaths) throws {
    try FileManager.default.createDirectory(at: paths.rawPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bundle.rawBytes.write(to: paths.rawPath, options: .atomic)

    try FileManager.default.createDirectory(at: paths.manifestPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (CanonicalJSON.data(for: bundle.manifest) + Data([0x0a])).write(to: paths.manifestPath, options: .atomic)
    try (CanonicalJSON.data(for: bundle.collectedSource) + Data([0x0a])).write(to: paths.collectedPath, options: .atomic)
    try bundle.curatedNoteMD.write(to: paths.notePath, atomically: true, encoding: .utf8)
}

private func validateBundleParity(_ bundle: WebCaptureBundle) throws {
    guard bundle.manifest.sourceID == bundle.collectedSource.sourceID else {
        throw ASKError.validation("capture manifest and collected source source_id must match")
    }
    guard bundle.manifest.rawRelpath == bundle.collectedSource.rawRelpath else {
        throw ASKError.validation("capture manifest and collected source raw_relpath must match")
    }
    guard bundle.manifest.contentHash == bundle.collectedSource.contentHash else {
        throw ASKError.validation("capture manifest and collected source content_hash must match")
    }
    guard webSHA256Prefixed(bundle.rawBytes) == bundle.manifest.contentHash else {
        throw ASKError.validation("capture raw bytes do not match content_hash")
    }
}

private func validateStagingPaths(_ paths: StagedCapturePaths) throws {
    let standardizedRoot = paths.stagingRoot.standardizedFileURL
    guard standardizedRoot.resolvingSymlinksInPath() == standardizedRoot else {
        throw ASKError.validation("capture staging root contains a symbolic link")
    }
    let root = standardizedRoot.path
    let targets = [paths.rawPath, paths.manifestPath, paths.collectedPath, paths.notePath]
    let targetPaths = Set(targets.map { $0.standardizedFileURL.path })
    guard targetPaths.count == targets.count else {
        throw ASKError.validation("capture staging paths must be unique")
    }
    for target in targets {
        let candidate = target.standardizedFileURL.path
        guard candidate == root || candidate.hasPrefix(root + "/") else {
            throw ASKError.validation("capture staging path escapes staging root")
        }
        try rejectSymbolicLinkComponents(root: paths.stagingRoot, target: target)
    }
}

private func rejectSymbolicLinkComponents(root: URL, target: URL) throws {
    let rootPath = root.standardizedFileURL.path
    let candidatePath = target.standardizedFileURL.path
    guard candidatePath.hasPrefix(rootPath + "/") else { return }
    let relative = String(candidatePath.dropFirst(rootPath.count + 1))
    var current = root
    for component in relative.split(separator: "/") {
        current.appendPathComponent(String(component), isDirectory: false)
        do {
            _ = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
            throw ASKError.validation("capture staging path contains symbolic link: \(current.path)")
        } catch let error as ASKError {
            throw error
        } catch let error as NSError {
            guard error.domain == NSCocoaErrorDomain,
                  error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError
            else {
                throw error
            }
        }
    }
}

private struct StagedCaptureCommitState {
    let target: URL
    let backup: URL
    let hadExistingTarget: Bool
}

private func commitStagedCapture(
    from staged: StagedCapturePaths,
    to targets: StagedCapturePaths,
    transactionRoot: URL
) throws {
    let pairs = [
        (staged.rawPath, targets.rawPath),
        (staged.manifestPath, targets.manifestPath),
        (staged.collectedPath, targets.collectedPath),
        (staged.notePath, targets.notePath),
    ]
    var committed: [StagedCaptureCommitState] = []
    do {
        for (index, pair) in pairs.enumerated() {
            try FileManager.default.createDirectory(
                at: pair.1.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let hadExistingTarget = FileManager.default.fileExists(atPath: pair.1.path)
            let backup = transactionRoot.appendingPathComponent("backup-\(index)")
            if hadExistingTarget {
                try FileManager.default.moveItem(at: pair.1, to: backup)
            }
            committed.append(StagedCaptureCommitState(
                target: pair.1,
                backup: backup,
                hadExistingTarget: hadExistingTarget
            ))
            try FileManager.default.moveItem(at: pair.0, to: pair.1)
        }
    } catch {
        let commitError = error
        var rollbackFailures: [String] = []
        for state in committed.reversed() {
            do {
                if FileManager.default.fileExists(atPath: state.target.path) {
                    try FileManager.default.removeItem(at: state.target)
                }
                if state.hadExistingTarget {
                    try FileManager.default.moveItem(at: state.backup, to: state.target)
                }
            } catch {
                rollbackFailures.append("\(state.target.path): \(error)")
            }
        }
        if rollbackFailures.isEmpty {
            throw commitError
        }
        throw ASKError.apply(
            "capture staging failed: \(commitError); rollback failed: \(rollbackFailures.joined(separator: "; "))"
        )
    }
}
