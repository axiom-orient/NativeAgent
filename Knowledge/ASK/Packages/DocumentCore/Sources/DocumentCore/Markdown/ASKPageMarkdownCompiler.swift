import Foundation

public struct ASKPageMarkdownCompiler: Sendable {
    public init() {}

    public func compile(
        markdown: String,
        documentID: ASKPageDocumentID,
        sourceID: ASKPageSourceID,
        title: String? = nil,
        authoritativeMarkdownPath: String? = nil
    ) -> ASKPageDocument {
        let parser = ASKMarkdownDocumentParser(markdown: markdown, sourceID: sourceID)
        let result = parser.parse()
        let resolvedTitle = title ?? result.sections.first?.title ?? "Untitled"
        return ASKPageDocument(
            id: documentID,
            title: resolvedTitle,
            source: .init(kind: .markdown, authoritativeMarkdownPath: authoritativeMarkdownPath),
            sections: result.sections,
            blocks: result.blocks
        )
    }
}
