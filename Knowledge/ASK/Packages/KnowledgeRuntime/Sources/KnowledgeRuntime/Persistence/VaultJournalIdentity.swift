import Foundation
import KnowledgeCore

extension Vault {
    /// Identity of the journal as it is on disk right now.
    ///
    /// Built from names, sizes and modification times in a single directory walk:
    /// journal files are written once and never rewritten in place, so this
    /// distinguishes every state the journal reaches through the supported API
    /// without reading or parsing a single entry. It is a cache key, not an
    /// integrity check — a deliberate rewrite that preserves size and timestamp
    /// is indistinguishable, exactly as it is for any other derived output.
    /// Fingerprint plus the newest journal modification time, from one walk.
    /// The canonical generation is a function of exactly this: what the journal
    /// holds and when it last changed.
    package func journalIdentity() throws -> (fingerprint: String, modifiedAt: Date) {
        let journalRoot = root.appendingPathComponent(".ask/journal", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: journalRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return (ASKSHA256.prefixedDigest(Data()), Date(timeIntervalSince1970: 0))
        }
        guard let enumerator = FileManager.default.enumerator(
            at: journalRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        ) else {
            throw ASKError.apply("unable to enumerate journal at `\(journalRoot.path)`")
        }

        let basePath = journalRoot.standardizedFileURL.path
        var lines: [String] = []
        var newest = Date(timeIntervalSince1970: 0)
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(basePath + "/") ? String(path.dropFirst(basePath.count + 1)) : path
            let size = values.fileSize ?? -1
            let modifiedDate = values.contentModificationDate
            if let modifiedDate, modifiedDate > newest { newest = modifiedDate }
            let modified = modifiedDate?.timeIntervalSince1970 ?? -1
            lines.append("\(relative)\u{001F}\(size)\u{001F}\(String(format: "%.9f", modified))")
        }
        lines.sort()
        return (ASKSHA256.prefixedDigest(Data(lines.joined(separator: "\u{001E}").utf8)), newest)
    }

}
