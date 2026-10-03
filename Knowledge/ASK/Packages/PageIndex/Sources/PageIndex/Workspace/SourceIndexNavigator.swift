import Foundation

public enum SourceIndexNavigator {
    public static func node(forID nodeID: String, in nodes: [SourceIndexNode]) -> SourceIndexNode? {
        for currentNode in nodes {
            if currentNode.nodeID == nodeID { return currentNode }
            if let child = node(forID: nodeID, in: currentNode.children) { return child }
        }
        return nil
    }

    public static func sectionPath(forID nodeID: String, in nodes: [SourceIndexNode]) -> [String]? {
        for currentNode in nodes {
            if currentNode.nodeID == nodeID { return [currentNode.title] }
            if let childPath = sectionPath(forID: nodeID, in: currentNode.children) {
                return [currentNode.title] + childPath
            }
        }
        return nil
    }

    public static func makeAnchor(sourceID: SourceID, nodeID: String, in artifact: SourceIndexArtifact) -> SourceAnchor? {
        guard let node = node(forID: nodeID, in: artifact.document.rootNodes),
              let sectionPath = sectionPath(forID: nodeID, in: artifact.document.rootNodes)
        else {
            return nil
        }
        let excerpts = artifact.excerpts.filter { node.range.contains($0.index) }
        let snippet = excerpts.first?.content ?? node.snippet ?? node.summary ?? ""
        return SourceAnchor(
            sourceID: sourceID,
            sourceVersionChecksum: artifact.version.checksum,
            nodeID: nodeID,
            sectionPath: sectionPath,
            range: node.range,
            snippet: snippet
        )
    }

    public static func catalogEntries(sourceID: SourceID, in artifact: SourceIndexArtifact) -> [SourceCatalogEntry] {
        catalogEntries(sourceID: sourceID, nodes: artifact.document.rootNodes, parentPath: [])
    }

    private static func catalogEntries(sourceID: SourceID, nodes: [SourceIndexNode], parentPath: [String]) -> [SourceCatalogEntry] {
        var entries: [SourceCatalogEntry] = []
        for node in nodes {
            let sectionPath = parentPath + [node.title]
            entries.append(
                SourceCatalogEntry(
                    sourceID: sourceID,
                    nodeID: node.nodeID,
                    title: node.title,
                    sectionPath: sectionPath,
                    range: node.range,
                    summary: node.summary,
                    snippet: node.snippet
                )
            )
            entries.append(contentsOf: catalogEntries(sourceID: sourceID, nodes: node.children, parentPath: sectionPath))
        }
        return entries
    }
}
