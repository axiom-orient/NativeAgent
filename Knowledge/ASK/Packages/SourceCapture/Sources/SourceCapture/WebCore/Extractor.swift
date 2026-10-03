import Foundation
import KnowledgeCore

public enum WebExtractor {
    public static func extractPage(html: String, url: String) throws -> ExtractionResult {
        try extractPageThrowing(html: html, url: url)
    }
}

func extractPageThrowing(html: String, url: String) throws -> ExtractionResult {
    let document = try ASKHTMLParser.parse(html)
    let metadata = try extractDocumentMetadata(from: document, fallbackURL: url)
    let markdown = try extractMarkdown(from: document)
    let fragments = fragmentMarkdown(markdown)

    return ExtractionResult(
        title: metadata.title,
        canonicalURL: metadata.canonicalURL,
        language: metadata.language,
        description: metadata.description,
        publishedAt: metadata.publishedAt,
        markdown: markdown,
        fragments: fragments,
        siteName: metadata.siteName
    )
}
