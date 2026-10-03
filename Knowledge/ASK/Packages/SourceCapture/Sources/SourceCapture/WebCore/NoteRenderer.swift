import Foundation
import KnowledgeCore

public enum CuratedNoteRenderer {
    public static func render(
        sourceID: String,
        title: String,
        finalURL: String,
        observedAt: String,
        description: String?,
        markdown: String,
        metadata: ASKFields
    ) -> String {
        var lines: [String] = [
            "# \(title)",
            "",
            "## curated summary",
            "- source_id: \(sourceID)",
            "- url: \(finalURL)",
            "- observed_at: \(observedAt)",
            "- connector: \(connectorSummary(metadata))"
        ]
        if let description, !description.isEmpty {
            lines.append("- description: \(description)")
        }
        let canonicalURL = metadata["canonical_url"] ?? finalURL
        if !canonicalURL.isEmpty {
            lines.append("- canonical_url: \(canonicalURL)")
        }
        if let count = metadata["fragment_count"], !count.isEmpty {
            lines.append("- fragment_count: \(count)")
        }
        lines.append("")
        lines.append("## extracted")
        lines.append(markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func connectorSummary(_ metadata: ASKFields) -> String {
        let transport = metadata["capture_transport"] ?? ""
        let siteName = metadata["site_name"] ?? ""
        let trimmed = "\(transport):\(siteName)".trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return trimmed.isEmpty ? transport : trimmed
    }
}
