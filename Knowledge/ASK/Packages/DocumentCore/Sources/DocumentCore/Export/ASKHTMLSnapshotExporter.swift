
public struct ASKHTMLSnapshotExporter: Sendable {
    private let escaper = ASKMarkupEscaper()
    private let metadata: ASKExportMetadataAttributes

    public init() {
        self.metadata = ASKExportMetadataAttributes(escaper: escaper)
    }

    public func export(document: ASKRenderedDocument) -> String {
        var html = "<article class=\"askpage-document\">"
        for block in document.blocks {
            html += "<section class=\"askpage-block\" data-block-id=\"\(escaper.escape(block.blockID.rawValue))\" data-style=\"\(escaper.escape(block.style.rawValue))\">"
            for line in block.lines {
                html += "<p class=\"askpage-line\" data-range-start=\"\(line.sourceRange.start)\" data-range-end=\"\(line.sourceRange.end)\">"
                for fragment in line.fragments {
                    html += renderFragment(fragment)
                }
                html += "</p>"
            }
            html += "</section>"
        }
        html += "</article>"
        return html
    }

    public func export(canvasPage: ASKRenderedCanvasPage) -> String {
        var html = "<section class=\"askpage-canvas\" data-canvas-id=\"\(escaper.escape(canvasPage.id.rawValue))\">"
        for fragment in canvasPage.textFragments {
            html += renderCanvasFragment(fragment)
        }
        for note in canvasPage.notes {
            html += renderCanvasNote(note)
        }
        html += "</section>"
        return html
    }

    private func renderFragment(_ fragment: ASKRenderedInlineFragment) -> String {
        let attributes = inlineMetadataAttributes(for: fragment)
        return "<span \(attributes.joined(separator: " "))>\(escaper.escape(fragment.text))</span>"
    }

    private func renderCanvasFragment(_ fragment: ASKRenderedCanvasTextFragment) -> String {
        let style = "style=\"position:absolute;left:\(fragment.frame.origin.x)px;top:\(fragment.frame.origin.y)px;width:\(fragment.frame.size.width)px;height:\(fragment.frame.size.height)px;\""
        let attributes = ([style] + canvasMetadataAttributes(for: fragment)).joined(separator: " ")
        return "<span \(attributes)>\(escaper.escape(fragment.text))</span>"
    }

    private func renderCanvasNote(_ note: ASKRenderedCanvasNote) -> String {
        let attributes = [
            "data-note=\"true\"",
            "style=\"position:absolute;left:\(note.frame.origin.x)px;top:\(note.frame.origin.y)px;width:\(note.frame.size.width)px;height:\(note.frame.size.height)px;\""
        ] + metadata.sourceAttributes(anchor: note.sourceAnchor)
        return "<aside \(attributes.joined(separator: " "))>\(escaper.escape(note.text))</aside>"
    }

    private func inlineMetadataAttributes(for fragment: ASKRenderedInlineFragment) -> [String] {
        metadata.sourceAttributes(anchor: fragment.sourceAnchor)
            + metadata.semanticAttributes(role: fragment.semanticRole)
            + metadata.destinationAttributes(fragment.destination)
            + metadata.emphasisAttributes(fragment.emphasis)
    }

    private func canvasMetadataAttributes(for fragment: ASKRenderedCanvasTextFragment) -> [String] {
        metadata.blockIDAttributes(fragment.blockID)
            + metadata.sourceAttributes(anchor: fragment.sourceAnchor)
            + metadata.semanticAttributes(role: fragment.semanticRole)
            + metadata.destinationAttributes(fragment.destination)
            + metadata.emphasisAttributes(fragment.emphasis)
    }
}
