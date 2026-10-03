import Foundation

private let extractionNoiseTags: Set<String> = [
    "script", "style", "noscript", "template", "svg", "footer", "nav", "form", "button", "dialog", "aside"
]

func preferredContentRoot(in document: ASKHTMLDocument) throws -> ASKHTMLElement? {
    if let article = try document.select("article").first {
        return article
    }
    if let main = try document.select("main").first {
        return main
    }
    return document.body ?? document.documentElement
}

func extractMarkdown(from document: ASKHTMLDocument) throws -> String {
    guard let root = try preferredContentRoot(in: document) else {
        return normalizedMarkdown(document.normalizedText)
    }

    let blocks = collectBlocks(from: root)
    guard !blocks.isEmpty else {
        return normalizedMarkdown(root.normalizedText)
    }
    return normalizedMarkdown(blocks.joined(separator: "\n\n"))
}

private func collectBlocks(from root: ASKHTMLElement) -> [String] {
    if let block = markdownBlock(for: root), !["article", "main", "body", "html"].contains(root.name.lowercased()) {
        return [block]
    }

    var output: [String] = []
    collectBlocks(from: root.children, into: &output)
    return output
}

private func collectBlocks(from nodes: [ASKHTMLNode], into output: inout [String]) {
    for node in nodes {
        guard case .element(let element) = node else { continue }
        if shouldSkip(element) { continue }
        if let block = markdownBlock(for: element) {
            output.append(block)
            continue
        }
        collectBlocks(from: element.children, into: &output)
    }
}

private func markdownBlock(for element: ASKHTMLElement) -> String? {
    let tag = element.name.lowercased()
    switch tag {
    case "pre":
        let raw = rawText(from: element.children).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return "```\n\(raw)\n```"
    case "blockquote":
        let text = collapseWhitespace(lineAwareText(from: element.children).replacingOccurrences(of: "\r\n", with: "\n"))
        guard !text.isEmpty else { return nil }
        return "> \(text)"
    case "li":
        let text = collapseWhitespace(element.normalizedText)
        guard !text.isEmpty else { return nil }
        return "- \(text)"
    case "h1", "h2", "h3", "h4", "h5", "h6":
        let text = collapseWhitespace(element.normalizedText)
        guard !text.isEmpty else { return nil }
        let level = Int(String(tag.dropFirst())) ?? 1
        return "\(String(repeating: "#", count: max(1, min(level, 6)))) \(text)"
    case "p":
        let text = collapseWhitespace(element.normalizedText)
        return text.isEmpty ? nil : text
    default:
        return nil
    }
}

private func shouldSkip(_ element: ASKHTMLElement) -> Bool {
    let name = element.name.lowercased()
    if extractionNoiseTags.contains(name) {
        return true
    }
    return element.attribute(named: "aria-hidden")?.lowercased() == "true"
}

private func rawText(from nodes: [ASKHTMLNode]) -> String {
    var output = ""
    for node in nodes {
        switch node {
        case .text(let textNode):
            output += textNode
        case .data(let dataNode):
            output += dataNode
        case .comment, .doctype:
            continue
        case .element(let element):
            if shouldSkip(element) { continue }
            if element.name.lowercased() == "br" {
                output += "\n"
            } else {
                output += rawText(from: element.children)
            }
        }
    }
    return output
}

private func lineAwareText(from nodes: [ASKHTMLNode]) -> String {
    var parts: [String] = []
    collectLineAwareText(from: nodes, into: &parts)
    return parts.joined(separator: " ")
}

private func collectLineAwareText(from nodes: [ASKHTMLNode], into parts: inout [String]) {
    for node in nodes {
        switch node {
        case .text(let textNode):
            let normalized = collapseWhitespace(textNode)
            if !normalized.isEmpty {
                parts.append(normalized)
            }
        case .data(let dataNode):
            let normalized = collapseWhitespace(dataNode)
            if !normalized.isEmpty {
                parts.append(normalized)
            }
        case .comment, .doctype:
            continue
        case .element(let element):
            if shouldSkip(element) { continue }
            if element.name.lowercased() == "br" {
                parts.append("\n")
                continue
            }
            collectLineAwareText(from: element.children, into: &parts)
            if ["p", "li", "blockquote", "pre", "div", "section", "article"].contains(element.name.lowercased()) {
                parts.append("\n")
            }
        }
    }
}
