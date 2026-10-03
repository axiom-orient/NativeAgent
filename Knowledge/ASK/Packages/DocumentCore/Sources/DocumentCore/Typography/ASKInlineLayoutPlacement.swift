
package struct ASKInlineLayoutPlacement: Sendable, Hashable {
    package let text: String
    package let layoutRange: ASKPageSourceRange
    package let emphasis: ASKPageInlineEmphasis
    package let destination: String?
    package let semanticRole: ASKPageInlineSemanticRole?
    package let sourceAnchor: ASKPageSourceAnchor?

    package init(
        text: String,
        layoutRange: ASKPageSourceRange,
        emphasis: ASKPageInlineEmphasis,
        destination: String?,
        semanticRole: ASKPageInlineSemanticRole?,
        sourceAnchor: ASKPageSourceAnchor?
    ) {
        self.text = text
        self.layoutRange = layoutRange
        self.emphasis = emphasis
        self.destination = destination
        self.semanticRole = semanticRole
        self.sourceAnchor = sourceAnchor
    }

    package func fragmentText(overlapping overlap: ASKPageSourceRange) -> String {
        let localStart = overlap.start - layoutRange.start
        let localEnd = overlap.end - layoutRange.start
        return text.askPageSubstring(start: localStart, end: localEnd)
    }

    package func projectedSourceAnchor(
        overlapping overlap: ASKPageSourceRange,
        fallbackFragment: String? = nil
    ) -> ASKPageSourceAnchor? {
        guard let sourceAnchor else {
            return nil
        }
        guard let anchorRange = sourceAnchor.range else {
            return sourceAnchor
        }

        let localStart = overlap.start - layoutRange.start
        let localEnd = overlap.end - layoutRange.start
        let fragmentRange = ASKPageSourceRange(
            start: anchorRange.start + localStart,
            end: anchorRange.start + localEnd
        )
        return ASKPageSourceAnchor(
            sourceID: sourceAnchor.sourceID,
            fragment: sourceAnchor.fragment ?? fallbackFragment,
            range: fragmentRange
        )
    }
}

package enum ASKInlineLayoutPlacementBuilder {
    package static func build(from runs: [ASKPageInlineRun]) -> [ASKInlineLayoutPlacement] {
        var offset = 0
        return runs.map { run in
            let start = offset
            let end = start + run.text.count
            defer { offset = end }
            return ASKInlineLayoutPlacement(
                text: run.text,
                layoutRange: .init(start: start, end: end),
                emphasis: run.emphasis,
                destination: run.destination?.absoluteString,
                semanticRole: run.semanticRole,
                sourceAnchor: run.sourceAnchor
            )
        }
    }
}

private extension String {
    func askPageSubstring(start: Int, end: Int) -> String {
        guard start < end else { return "" }
        let lower = index(startIndex, offsetBy: start)
        let upper = index(startIndex, offsetBy: end)
        return String(self[lower..<upper])
    }
}
