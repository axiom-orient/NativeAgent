
struct ASKMarkdownBlockProjection {
    func flattenBlocksToRuns(_ blocks: [ASKPageBlock], blockSeparator: String) -> [ASKPageInlineRun] {
        var runs: [ASKPageInlineRun] = []
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                runs.append(.init(text: blockSeparator))
            }
            runs.append(contentsOf: flattenedRuns(for: block))
        }
        return runs
    }

    func flattenListItemBlocksToRuns(_ blocks: [ASKPageBlock]) -> [ASKPageInlineRun] {
        var runs: [ASKPageInlineRun] = []
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                runs.append(.init(text: "\n"))
            }

            let blockRuns = flattenedRuns(for: block)
            if shouldIndentListItemBlock(block: block, index: index) {
                runs.append(contentsOf: prefixLines(of: blockRuns, with: "  "))
            } else {
                runs.append(contentsOf: blockRuns)
            }
        }
        return runs
    }

    func flattenedRuns(for block: ASKPageBlock) -> [ASKPageInlineRun] {
        switch block.kind {
        case .quote:
            guard let projection = block.textProjection else {
                return []
            }
            return prefixLines(of: projection.runs, with: "> ")
        case .canvas(let reference):
            return [
                .init(
                    text: "[canvas: \(reference.sceneID.rawValue)]",
                    sourceAnchor: block.sourceAnchor
                )
            ]
        default:
            return block.textProjection?.runs ?? []
        }
    }

    private func shouldIndentListItemBlock(block: ASKPageBlock, index: Int) -> Bool {
        if index == 0 {
            switch block.kind {
            case .paragraph, .heading:
                return false
            default:
                return true
            }
        }
        return true
    }

    private func prefixLines(of runs: [ASKPageInlineRun], with prefix: String) -> [ASKPageInlineRun] {
        guard !runs.isEmpty, !prefix.isEmpty else {
            return runs
        }

        var prefixed: [ASKPageInlineRun] = []
        var startOfLine = true
        for run in runs {
            let parts = run.text.split(separator: "\n", omittingEmptySubsequences: false)
            var consumedCharacters = 0

            for (index, part) in parts.enumerated() {
                let segmentText = String(part)
                let segmentLength = segmentText.count
                if startOfLine {
                    prefixed.append(.init(text: prefix))
                }
                if segmentLength > 0 {
                    prefixed.append(slice(run: run, offset: consumedCharacters, length: segmentLength, text: segmentText))
                    consumedCharacters += segmentLength
                }
                if index < parts.count - 1 {
                    prefixed.append(.init(text: "\n"))
                    consumedCharacters += 1
                    startOfLine = true
                } else {
                    startOfLine = false
                }
            }
        }
        return prefixed
    }

    private func slice(run: ASKPageInlineRun, offset: Int, length: Int, text: String) -> ASKPageInlineRun {
        guard let anchor = run.sourceAnchor, let range = anchor.range else {
            return .init(
                text: text,
                emphasis: run.emphasis,
                destination: run.destination,
                semanticRole: run.semanticRole,
                sourceAnchor: run.sourceAnchor
            )
        }

        let projectedRange = ASKPageSourceRange(start: range.start + offset, end: range.start + offset + length)
        return .init(
            text: text,
            emphasis: run.emphasis,
            destination: run.destination,
            semanticRole: run.semanticRole,
            sourceAnchor: .init(sourceID: anchor.sourceID, fragment: anchor.fragment, range: projectedRange)
        )
    }
}
