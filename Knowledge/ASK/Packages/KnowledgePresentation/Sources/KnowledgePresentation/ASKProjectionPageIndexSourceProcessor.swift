import Foundation
import KnowledgeRuntime
import PageIndex

struct ASKProjectionPageIndexSourceProcessor {
    let knowledgeRoot: URL
    let pageIndex: ASKPageIndexMacService
    let fileManager: FileManager
    /// Canonical receipts for the projection's sources, fetched once by the
    /// builder rather than read per source from the vault's file layout.
    let sourceReceipts: [String: SourceReceipt]

    func process(askSourceID: String) async -> ASKProjectionPageIndexSourceOutput {
        do {
            guard let receipt = sourceReceipts[askSourceID] else {
                throw ASKKnowledgeWorkspaceError.projectionNotFound(askSourceID)
            }
            try receipt.validate()
            let rawURL = knowledgeRoot.appendingPathComponent(receipt.rawRelpath, isDirectory: false)
            guard supportsPageIndex(rawURL) else {
                return .init(
                    entry: ASKProjectionPageIndexBuildEntry(
                        askSourceID: askSourceID,
                        pageIndexSourceID: nil,
                        title: receipt.title,
                        rawRelpath: receipt.rawRelpath,
                        status: .unsupportedFileFormat,
                        detail: "unsupported_file_format"
                    ),
                    binding: nil,
                    anchors: []
                )
            }

            let manifestEntry = try await pageIndex.build(sourceAt: rawURL)
            let catalog = try await pageIndex.catalog(sourceID: manifestEntry.sourceID)
            let rootAnchors = try await rootAnchors(for: manifestEntry.sourceID)
            let binding = ASKPageIndexSourceBinding(
                askSourceID: askSourceID,
                pageIndexSourceID: manifestEntry.sourceID
            )
            return .init(
                entry: ASKProjectionPageIndexBuildEntry(
                    askSourceID: askSourceID,
                    pageIndexSourceID: manifestEntry.sourceID,
                    title: receipt.title,
                    rawRelpath: receipt.rawRelpath,
                    status: .indexed,
                    catalogEntryCount: catalog.count,
                    rootAnchorCount: rootAnchors.count
                ),
                binding: binding,
                anchors: rootAnchors
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .init(
                entry: ASKProjectionPageIndexBuildEntry(
                    askSourceID: askSourceID,
                    pageIndexSourceID: nil,
                    title: nil,
                    rawRelpath: nil,
                    status: .missingSourceReceipt,
                    detail: "missing_source_receipt"
                ),
                binding: nil,
                anchors: []
            )
        } catch ASKPageIndexError.fileNotFound {
            return .init(
                entry: ASKProjectionPageIndexBuildEntry(
                    askSourceID: askSourceID,
                    pageIndexSourceID: nil,
                    title: nil,
                    rawRelpath: nil,
                    status: .missingRawFile,
                    detail: "missing_raw_file"
                ),
                binding: nil,
                anchors: []
            )
        } catch {
            return .init(
                entry: ASKProjectionPageIndexBuildEntry(
                    askSourceID: askSourceID,
                    pageIndexSourceID: nil,
                    title: nil,
                    rawRelpath: nil,
                    status: .failed,
                    detail: String(describing: error)
                ),
                binding: nil,
                anchors: []
            )
        }
    }

    private func rootAnchors(for sourceID: SourceID) async throws -> [SourceAnchor] {
        guard let artifact = try await pageIndex.artifact(sourceID: sourceID) else {
            return []
        }

        var result: [SourceAnchor] = []
        for node in artifact.document.rootNodes {
            if let anchor = SourceIndexNavigator.makeAnchor(sourceID: sourceID, nodeID: node.nodeID, in: artifact) {
                result.append(anchor)
            }
        }
        return result
    }

    private func supportsPageIndex(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "pdf":
            true
        default:
            false
        }
    }
}

struct ASKProjectionPageIndexSourceOutput {
    let entry: ASKProjectionPageIndexBuildEntry
    let binding: ASKPageIndexSourceBinding?
    let anchors: [SourceAnchor]
}
