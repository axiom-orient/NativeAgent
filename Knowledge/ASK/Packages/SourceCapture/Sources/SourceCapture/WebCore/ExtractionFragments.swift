import Foundation
import KnowledgeCore

func fragmentMarkdown(_ markdown: String, maxFragments: Int = 32) -> [ExtractionFragment] {
    let blocks = markdown
        .components(separatedBy: "\n\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    var fragments: [ExtractionFragment] = []
    var currentHeading = ""
    var ordinal = 1
    for block in blocks {
        if block.hasPrefix("#") {
            currentHeading = block.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            continue
        }
        var text = block
        if text.count < 24 { continue }
        if text.count > 1200 {
            text = String(text.prefix(1200)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        var locator: ASKFields = ["block": "\(ordinal)"]
        if !currentHeading.isEmpty { locator["heading"] = currentHeading }
        fragments.append(
            ExtractionFragment(
                ordinal: ordinal,
                text: text,
                heading: currentHeading,
                locator: locator,
                fingerprint: shortFingerprint(text)
            )
        )
        ordinal += 1
        if fragments.count >= maxFragments { break }
    }
    return fragments
}
