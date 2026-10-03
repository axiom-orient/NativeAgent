import Foundation
import PageIndex

public enum ASKEvidencePackRenderer {
    public static func render(queryText: String, hits: [ASKEvidenceHit], maxBytes: Int) -> ASKEvidencePack {
        let budget = max(0, maxBytes)
        var markdown = "# Evidence Pack\n\nQuery: \(queryText)\n\n"
        var included: [ASKEvidenceHit] = []
        var truncated = false

        if byteCount(markdown) > budget {
            let clipped = hardPrefix(markdown, maxBytes: budget)
            return ASKEvidencePack(queryText: queryText, hits: [], renderedMarkdown: clipped, maxBytes: budget, truncated: true)
        }

        for (index, hit) in hits.enumerated() {
            let chunk = renderChunk(index: index + 1, hit: hit)
            if byteCount(markdown + chunk) > budget {
                truncated = true
                break
            }
            markdown += chunk
            included.append(hit)
        }

        return ASKEvidencePack(queryText: queryText, hits: included, renderedMarkdown: markdown, maxBytes: budget, truncated: truncated)
    }

    private static func renderChunk(index: Int, hit: ASKEvidenceHit) -> String {
        let path = hit.metadata.sourcePath ?? hit.sourceID.rawValue
        let locator: String
        switch hit.range.space {
        case .line:
            locator = "L\(hit.range.start)-L\(hit.range.end)"
        case .page:
            locator = "P\(hit.range.start)-P\(hit.range.end)"
        }
        let section = hit.sectionPath.joined(separator: " > ")
        let tags = hit.metadata.tags.isEmpty ? "" : "\nTags: \(hit.metadata.tags.joined(separator: ", "))"
        return """
        ## [\(index)] \(hit.title)

        Source: \(path)#\(locator)
        Section: \(section)
        Freshness: \(hit.freshness.rawValue)
        Score: \(String(format: "%.2f", hit.score))\(tags)

        ```text
        \(hit.excerpt)
        ```

        """
    }

    private static func byteCount(_ text: String) -> Int {
        text.data(using: .utf8)?.count ?? 0
    }

    private static func hardPrefix(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var output = ""
        var used = 0
        for scalar in text.unicodeScalars {
            let fragment = String(scalar)
            let bytes = fragment.data(using: .utf8)?.count ?? 0
            if used + bytes > maxBytes { break }
            output.append(fragment)
            used += bytes
        }
        return output
    }
}
