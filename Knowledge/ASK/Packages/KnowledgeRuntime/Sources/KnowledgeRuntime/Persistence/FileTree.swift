import Foundation
import KnowledgeCore

func persistenceRelativeFiles(in root: URL) throws -> [String] {
    try persistenceFileEntries(in: root).map(\.relativePath)
}

package struct PersistenceFileEntry {
    package let relativePath: String
    package let modifiedAt: Date?
}

/// One walk that yields both the relative paths and their modification times.
///
/// The root is canonicalized once and descendants are named by accumulating the
/// components walked into them: resolving symlinks per file made this walk the
/// most expensive part of writing a generation marker, and it never changed the
/// answer, since the walk only ever descends into directories under the root.
package func persistenceFileEntries(in root: URL) throws -> [PersistenceFileEntry] {
    let canonicalRoot = root.resolvingSymlinksInPath()
    var output: [PersistenceFileEntry] = []
    try collectRelativeFiles(current: canonicalRoot, prefix: "", into: &output)
    return output.sorted { $0.relativePath < $1.relativePath }
}

private func collectRelativeFiles(current: URL, prefix: String, into output: inout [PersistenceFileEntry]) throws {
    let children = try FileManager.default.contentsOfDirectory(
        at: current,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey],
        options: [.skipsPackageDescendants]
    )
    for child in children {
        let name = child.lastPathComponent
        if name == ".DS_Store" { continue }
        let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey])
        if values.isDirectory == true {
            try collectRelativeFiles(current: child, prefix: prefix + name + "/", into: &output)
            continue
        }
        guard values.isRegularFile == true else { continue }
        let relative = prefix + name
        if relative.contains("__MACOSX") { continue }
        output.append(PersistenceFileEntry(relativePath: relative, modifiedAt: values.contentModificationDate))
    }
}
