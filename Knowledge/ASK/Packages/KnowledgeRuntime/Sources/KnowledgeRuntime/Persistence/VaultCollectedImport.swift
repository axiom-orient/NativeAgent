import Foundation
import KnowledgeCore

extension Vault {
    package func importCollected(_ captureManifestURL: URL) throws -> ASKImportedCapture {
        // Read and validate the complete input before publishing any bytes.
        // This snapshot also prevents later reads from observing a different
        // note/metadata revision after the raw file has already been imported.
        let (manifestPath, captureDir, stagingRoot, collectorFamily) = try Self.resolveCapturePaths(captureManifestURL)
        let manifest = try CanonicalJSON.decode(CollectedCaptureManifest.self,
            from: CaptureFileBoundary.read(manifestPath, within: stagingRoot))
        try manifest.validate()
        var collected = try CanonicalJSON.decode(CollectedSource.self,
            from: CaptureFileBoundary.read(captureDir.appendingPathComponent("collected_source.json"), within: stagingRoot))
        try collected.validate()
        guard manifest.sourceID == collected.sourceID,
              captureDir.lastPathComponent == manifest.sourceID else {
            throw ASKError.validation("capture directory, manifest and collected source source_id must match")
        }
        guard manifest.rawRelpath == collected.rawRelpath else {
            throw ASKError.validation("capture manifest raw_relpath does not match collected_source")
        }
        let noteRelpath = ".ask/collector/\(collectorFamily)/\(manifest.sourceID)/curated_note.md"
        guard manifest.noteRelpath == noteRelpath else {
            throw ASKError.validation("capture manifest note_relpath does not match its curated note")
        }
        let rawBytes = try CaptureFileBoundary.read(stagingRoot.appendingPathComponent(manifest.rawRelpath), within: stagingRoot)
        let actualHash = sha256Prefixed(rawBytes)
        guard actualHash == manifest.contentHash, actualHash == collected.contentHash else {
            throw ASKError.importIntegrity("capture manifest, collected source and raw bytes must have the same SHA-256")
        }
        let noteBytes = try CaptureFileBoundary.read(captureDir.appendingPathComponent("curated_note.md"), within: stagingRoot)
        guard let noteText = String(data: noteBytes, encoding: .utf8) else {
            throw ASKError.validation("captured curated note is not valid UTF-8")
        }
        collected.metadata["curated_note_excerpt"] = curatedNoteExcerpt(noteText)
        collected.metadata["curated_note_relpath"] = noteRelpath
        collected.metadata = normalizedCollectedSourceMetadata(collected)
        let manifestData = try CanonicalJSON.data(for: manifest) + Data([0x0a])
        let collectedData = try CanonicalJSON.data(for: collected) + Data([0x0a])

        return try withMaterializeLock {
            let sourceID = manifest.sourceID
            let rawRelpath = manifest.rawRelpath
            let targetRawURL = root.appendingPathComponent(rawRelpath)
            let targetCaptureDir = root.appendingPathComponent(".ask/collector/\(collectorFamily)/\(sourceID)", isDirectory: true)
            let targets = [targetRawURL] + ["capture_manifest.json", "collected_source.json", "curated_note.md"]
                .map { targetCaptureDir.appendingPathComponent($0) }
            for target in targets { try CaptureFileBoundary.validateOutput(target, within: root) }
            if FileManager.default.fileExists(atPath: targetRawURL.path) {
                guard try CaptureFileBoundary.read(targetRawURL, within: root) == rawBytes else {
                    throw ASKError.importIntegrity("raw evidence already exists with different bytes; use a new raw_relpath for the new revision")
                }
            } else {
                try writeBytesFile(targetRawURL, content: rawBytes)
            }

            try writeBytesFile(targetCaptureDir.appendingPathComponent("capture_manifest.json"), content: manifestData)
            try writeBytesFile(targetCaptureDir.appendingPathComponent("collected_source.json"), content: collectedData)
            try writeTextFile(targetCaptureDir.appendingPathComponent("curated_note.md"), content: noteText)

            return ASKImportedCapture(
                sourceID: sourceID,
                rawRelpath: rawRelpath,
                contentHash: manifest.contentHash,
                rawPath: targetRawURL.path,
                manifestPath: targetCaptureDir.appendingPathComponent("capture_manifest.json").path,
                collectedPath: targetCaptureDir.appendingPathComponent("collected_source.json").path,
                notePath: targetCaptureDir.appendingPathComponent("curated_note.md").path
            )
        }
    }

    package static func resolveCapturePaths(_ inputURL: URL) throws -> (URL, URL, URL, String) {
        guard inputURL.isFileURL else { throw ASKError.validation("capture manifest must be a file URL") }
        let candidate = inputURL.standardizedFileURL
        let captureDir: URL
        let manifestPath: URL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
            captureDir = candidate
            manifestPath = captureDir.appendingPathComponent("capture_manifest.json")
        } else {
            manifestPath = candidate
            captureDir = candidate.deletingLastPathComponent()
        }
        guard FileManager.default.fileExists(atPath: manifestPath.path) else {
            throw ASKError.validation("missing capture manifest at `\(manifestPath.path)`")
        }

        let components = captureDir.pathComponents
        guard components.count >= 4 else {
            throw ASKError.validation("capture manifest must live under `<staging_root>/.ask/collector/<family>/<source_id>/capture_manifest.json`")
        }
        let suffix = Array(components.suffix(4))
        guard suffix[0] == ".ask", suffix[1] == "collector", suffix[2].isEmpty == false else {
            throw ASKError.validation("capture manifest must live under `<staging_root>/.ask/collector/<family>/<source_id>/capture_manifest.json`")
        }
        let collectorFamily = suffix[2]
        let stagingRoot = components.dropLast(4).reduce(URL(fileURLWithPath: "/", isDirectory: true)) { partial, part in
            part == "/" ? partial : partial.appendingPathComponent(part, isDirectory: true)
        }
        return (manifestPath, captureDir, stagingRoot, collectorFamily)
    }
}

/// The trusted root may itself have an OS alias (for example /var on macOS).
/// Descendant symlinks are not capture files, including links back into .ask.
private enum CaptureFileBoundary {
    static func validate(_ url: URL, within root: URL) throws -> URL {
        let base = root.standardizedFileURL
        let candidate = url.standardizedFileURL
        let prefix = base.path == "/" ? "/" : base.path + "/"
        guard candidate.path.hasPrefix(prefix), candidate.path != base.path else {
            throw ASKError.validation("capture path escapes its root")
        }
        let relative = candidate.path.dropFirst(prefix.count).split(separator: "/")
        var current = base.resolvingSymlinksInPath()
        for component in relative {
            current.appendPathComponent(String(component))
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                    throw ASKError.validation("capture path contains a symbolic link: \(current.path)")
                }
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                continue
            }
        }
        return current
    }

    static func validateOutput(_ url: URL, within root: URL) throws {
        let candidate = try validate(url, within: root)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ASKError.validation("capture output must be a regular file: \(candidate.path)")
            }
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // A new regular file will be created by the publication boundary.
        }
    }

    static func read(_ url: URL, within root: URL) throws -> Data {
        let candidate = try validate(url, within: root)
        let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ASKError.validation("capture input must be a regular file: \(candidate.path)")
        }
        return try Data(contentsOf: candidate)
    }
}
