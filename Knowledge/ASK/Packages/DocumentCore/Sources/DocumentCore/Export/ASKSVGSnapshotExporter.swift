
public struct ASKSVGSnapshotExporter: Sendable {
    private let escaper = ASKMarkupEscaper()
    private let metadata: ASKExportMetadataAttributes

    public init() {
        self.metadata = ASKExportMetadataAttributes(escaper: escaper)
    }

    public func export(document: ASKRenderedDocument, width: Double = 800, lineHeight: Double = 16) -> String {
        let totalLineCount = document.blocks.reduce(0) { $0 + $1.lines.count }
        let height = max(Double(totalLineCount) * lineHeight + 20, lineHeight)
        var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\">"
        var y = lineHeight
        for block in document.blocks {
            for line in block.lines {
                svg += "<text x=\"0\" y=\"\(y)\" data-block-id=\"\(escaper.escape(block.blockID.rawValue))\" data-range-start=\"\(line.sourceRange.start)\" data-range-end=\"\(line.sourceRange.end)\">"
                for fragment in line.fragments {
                    svg += renderFragment(fragment)
                }
                svg += "</text>"
                y += lineHeight
            }
        }
        svg += "</svg>"
        return svg
    }

    public func export(canvasPage: ASKRenderedCanvasPage) -> String {
        let maxX = canvasPage.textFragments.map { $0.frame.origin.x + $0.frame.size.width }.max() ?? 0
        let maxY = max(
            canvasPage.textFragments.map { $0.frame.origin.y + $0.frame.size.height }.max() ?? 0,
            canvasPage.notes.map { $0.frame.origin.y + $0.frame.size.height }.max() ?? 0
        )
        var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(max(maxX, 1))\" height=\"\(max(maxY, 1))\">"
        for fragment in canvasPage.textFragments {
            svg += renderCanvasFragment(fragment)
        }
        for note in canvasPage.notes {
            svg += renderCanvasNote(note)
        }
        svg += "</svg>"
        return svg
    }

    private func renderFragment(_ fragment: ASKRenderedInlineFragment) -> String {
        let attributes = inlineMetadataAttributes(for: fragment)
        return "<tspan \(attributes.joined(separator: " "))>\(escaper.escape(fragment.text))</tspan>"
    }

    private func renderCanvasFragment(_ fragment: ASKRenderedCanvasTextFragment) -> String {
        let attributes = canvasMetadataAttributes(for: fragment)
        let y = fragment.frame.origin.y + max(fragment.frame.size.height - 4, 0)
        return "<text x=\"\(fragment.frame.origin.x)\" y=\"\(y)\" \(attributes.joined(separator: " "))>\(escaper.escape(fragment.text))</text>"
    }

    private func renderCanvasNote(_ note: ASKRenderedCanvasNote) -> String {
        let attributes = ["data-note=\"true\""] + metadata.sourceAttributes(anchor: note.sourceAnchor)
        return "<g \(attributes.joined(separator: " "))><rect x=\"\(note.frame.origin.x)\" y=\"\(note.frame.origin.y)\" width=\"\(note.frame.size.width)\" height=\"\(note.frame.size.height)\" fill=\"none\" stroke=\"black\"/><text x=\"\(note.frame.origin.x + 4)\" y=\"\(note.frame.origin.y + note.frame.size.height - 4)\">\(escaper.escape(note.text))</text></g>"
    }

    private func inlineMetadataAttributes(for fragment: ASKRenderedInlineFragment) -> [String] {
        metadata.sourceAttributes(anchor: fragment.sourceAnchor)
            + metadata.semanticAttributes(role: fragment.semanticRole)
    }

    private func canvasMetadataAttributes(for fragment: ASKRenderedCanvasTextFragment) -> [String] {
        metadata.blockIDAttributes(fragment.blockID)
            + metadata.sourceAttributes(anchor: fragment.sourceAnchor)
            + metadata.semanticAttributes(role: fragment.semanticRole)
    }
}
