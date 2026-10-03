package struct ASKPageTextProjection: Sendable {
    package let text: String
    package let runs: [ASKPageInlineRun]
    package let style: ASKPageTextStyle

    package init(text: String, runs: [ASKPageInlineRun], style: ASKPageTextStyle) {
        self.text = text
        self.runs = runs
        self.style = style
    }
}

package extension ASKPageBlock {
    var textProjection: ASKPageTextProjection? {
        switch kind {
        case .heading(let block), .paragraph(let block), .quote(let block), .note(let block):
            return ASKPageTextProjection(
                text: block.runs.map(\.text).joined(),
                runs: block.runs,
                style: block.style
            )
        case .code(let block):
            let synthesizedRun = ASKPageInlineRun(
                text: block.text,
                sourceAnchor: sourceAnchor
            )
            return ASKPageTextProjection(
                text: block.text,
                runs: [synthesizedRun],
                style: .code
            )
        case .list(let block):
            let projectedRuns = synthesizeListRuns(block)
            return ASKPageTextProjection(
                text: projectedRuns.map(\.text).joined(),
                runs: projectedRuns,
                style: .body
            )
        case .canvas:
            return nil
        }
    }

    private func synthesizeListRuns(_ block: ASKPageListBlock) -> [ASKPageInlineRun] {
        var runs: [ASKPageInlineRun] = []
        for (index, itemRuns) in block.items.enumerated() {
            let marker = block.ordered ? "\(index + 1). " : "- "
            runs.append(.init(text: marker))
            runs.append(contentsOf: itemRuns)
            if index < block.items.count - 1 {
                runs.append(.init(text: "\n"))
            }
        }
        return runs
    }
}
