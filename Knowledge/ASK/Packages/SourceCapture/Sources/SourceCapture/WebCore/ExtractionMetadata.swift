import Foundation

package struct DocumentExtractionMetadata: Sendable, Equatable {
    package var title: String
    package var canonicalURL: String
    package var language: String?
    package var description: String?
    package var publishedAt: String?
    package var siteName: String?
}

func extractDocumentMetadata(from document: ASKHTMLDocument, fallbackURL: String) throws -> DocumentExtractionMetadata {
    DocumentExtractionMetadata(
        title: try extractTitle(from: document) ?? "Untitled page",
        canonicalURL: try extractCanonicalURL(from: document, fallbackURL: fallbackURL) ?? fallbackURL,
        language: extractLanguage(from: document),
        description: try extractDescription(from: document),
        publishedAt: try extractPublishedAt(from: document),
        siteName: try firstMetaContent(in: document, attribute: "property", value: "og:site_name")
    )
}

private func extractLanguage(from document: ASKHTMLDocument) -> String? {
    let normalized = collapseWhitespace(document.documentElement?.attribute(named: "lang") ?? "")
    return normalized.isEmpty ? nil : normalized
}

private func extractTitle(from document: ASKHTMLDocument) throws -> String? {
    let candidates: [String?] = [
        try firstMetaContent(in: document, attribute: "property", value: "og:title"),
        try firstMetaContent(in: document, attribute: "name", value: "twitter:title"),
        document.title,
        try firstHeadingText(in: preferredContentRoot(in: document))
    ]
    for candidate in candidates {
        let normalized = collapseWhitespace(candidate ?? "")
        if !normalized.isEmpty {
            return normalized
        }
    }
    return nil
}

private func extractCanonicalURL(from document: ASKHTMLDocument, fallbackURL: String) throws -> String? {
    let links = try document.select("link")
    for link in links {
        let rel = link.attribute(named: "rel")?.lowercased() ?? ""
        guard rel.split(whereSeparator: \.isWhitespace).contains("canonical") else { continue }
        let href = collapseWhitespace(link.attribute(named: "href") ?? "")
        guard !href.isEmpty else { continue }
        return absoluteURLString(href, relativeTo: fallbackURL)
    }
    return nil
}

private func extractDescription(from document: ASKHTMLDocument) throws -> String? {
    let candidates = [
        try firstMetaContent(in: document, attribute: "name", value: "description"),
        try firstMetaContent(in: document, attribute: "property", value: "og:description")
    ]
    for candidate in candidates {
        let normalized = collapseWhitespace(candidate ?? "")
        if !normalized.isEmpty {
            return normalized
        }
    }
    return nil
}

private func extractPublishedAt(from document: ASKHTMLDocument) throws -> String? {
    let candidates = [
        try firstMetaContent(in: document, attribute: "property", value: "article:published_time"),
        try firstMetaContent(in: document, attribute: "name", value: "article:published_time"),
        try document.select("time[datetime]").first?.attribute(named: "datetime")
    ]
    for candidate in candidates {
        let normalized = collapseWhitespace(candidate ?? "")
        if !normalized.isEmpty {
            return normalized
        }
    }
    return nil
}

private func firstMetaContent(in document: ASKHTMLDocument, attribute: String, value: String) throws -> String? {
    let metas = try document.select("meta")
    for meta in metas {
        guard meta.attribute(named: attribute)?.caseInsensitiveCompare(value) == .orderedSame else {
            continue
        }
        let content = collapseWhitespace(meta.attribute(named: "content") ?? "")
        if !content.isEmpty {
            return content
        }
    }
    return nil
}

private func firstHeadingText(in root: ASKHTMLElement?) throws -> String? {
    guard let root else { return nil }
    let headings = try root.select("h1, h2, h3")
    for heading in headings {
        let normalized = collapseWhitespace(heading.normalizedText)
        if !normalized.isEmpty {
            return normalized
        }
    }
    return nil
}

private func absoluteURLString(_ rawValue: String, relativeTo baseURL: String) -> String {
    if let absolute = URL(string: rawValue), absolute.scheme != nil {
        return absolute.absoluteString
    }
    if let base = URL(string: baseURL), let resolved = URL(string: rawValue, relativeTo: base)?.absoluteURL {
        return resolved.absoluteString
    }
    return rawValue
}
