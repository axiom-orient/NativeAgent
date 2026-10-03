import Foundation
import KnowledgeCore

package struct ASKWorkWikiProjectRootPolicy: Sendable {
    package var projectRoot: URL

    package init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    package func resolve() -> ASKWorkWikiProjectResolution {
        let canonicalRoot = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalPath = canonicalRoot.path
        let leaf = slugLeaf(from: canonicalRoot.lastPathComponent)
        let hash = String(stableHash([canonicalPath]).prefix(12))
        let slug = leaf.isEmpty ? "project-\(hash)" : "\(leaf)-\(hash)"
        return ASKWorkWikiProjectResolution(
            projectRootPath: canonicalPath,
            projectSlug: slug,
            source: .workspaceHash
        )
    }

    private func slugLeaf(from value: String) -> String {
        let lowered = value.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        return String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }
}
