import Foundation
import PageIndex

@main
struct IndexDriver {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            throw NSError(domain: "IndexDriver usage: <root> <put|inspect|recover|delete> <text>", code: 2)
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let store = try SourceIndexStore(workspaceURL: root.appendingPathComponent("index"))
        let source = root.appendingPathComponent("source.md")
        let id = SourceIdentityFactory.makeID(forFileAt: source)
        switch arguments[2] {
        case "put":
            let text = arguments[3], data = Data(text.utf8)
            let range = try SourceRange(space: .line, start: 1, end: 1)
            let artifact = SourceIndexArtifact(document: SourceIndexDocument(sourceID: id,
                type: .md, title: text, coordinateSpace: .line, extentCount: 1,
                rootNodes: [SourceIndexNode(nodeID: "root", title: text, range: range, snippet: text)]),
                excerpts: [SourceExcerpt(index: 1, content: text)],
                version: SourceIdentityFactory.makeVersion(data: data), sourcePath: source.path,
                extractionQuality: .digitalText)
            _ = try await store.put(artifact)
            print("published:\(text)")
        case "inspect":
            print(try await store.get(sourceID: id)?.document.title ?? "absent")
            print("history:\(try await store.history(sourceID: id).count)")
        case "recover": print("recovered:\(try await store.recoverPendingWrite())")
        case "delete": try await store.delete(sourceID: id); print("deleted")
        default: throw NSError(domain: "Unknown operation", code: 2)
        }
    }
}
