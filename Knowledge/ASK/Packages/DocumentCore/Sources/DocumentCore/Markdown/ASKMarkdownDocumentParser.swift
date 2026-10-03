import Foundation

struct ASKMarkdownDocumentParser {
    let markdown: String
    let sourceID: ASKPageSourceID

    func parse() -> (sections: [ASKPageSection], blocks: [ASKPageBlock]) {
        let lines = splitLines(markdown)
        var state = ASKMarkdownParserState()
        var sections: [ASKPageSection] = []
        let blocks = parseBlocks(
            lines: lines,
            state: &state,
            sections: &sections,
            currentSectionID: nil,
            recordsSections: true,
            parsesHeadings: true
        )
        return (sections, blocks)
    }

    private func parseBlocks(
        lines: [ASKMarkdownLine],
        state: inout ASKMarkdownParserState,
        sections: inout [ASKPageSection],
        currentSectionID: ASKPageSectionID?,
        recordsSections: Bool,
        parsesHeadings: Bool
    ) -> [ASKPageBlock] {
        let parser = ASKMarkdownBlockParser(lines: lines, sourceID: sourceID)
        var blocks: [ASKPageBlock] = []
        var paragraphBuffer: [ASKMarkdownLine] = []
        var activeSectionID = currentSectionID
        var index = 0

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else {
                return
            }
            let block = parser.makeParagraphBlock(
                lines: paragraphBuffer,
                blockID: state.nextParagraphBlockID(),
                sectionID: activeSectionID
            )
            blocks.append(block)
            paragraphBuffer.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]

            if line.trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if parsesHeadings, let heading = parser.parseHeading(line: line) {
                flushParagraph()
                let sectionID = recordsSections ? state.nextSectionID() : activeSectionID
                if recordsSections, let sectionID {
                    activeSectionID = sectionID
                    sections.append(
                        ASKPageSection(
                            id: sectionID,
                            title: heading.text,
                            level: heading.level,
                            sourceAnchor: .init(sourceID: sourceID, fragment: heading.fragment, range: heading.sourceRange)
                        )
                    )
                }
                blocks.append(
                    parser.makeHeadingBlock(
                        heading,
                        blockID: state.nextHeadingBlockID(),
                        sectionID: activeSectionID
                    )
                )
                index += 1
                continue
            }

            if let parsedCode = parser.parseCodeBlock(startingAt: index) {
                flushParagraph()
                blocks.append(
                    parser.makeCodeBlock(
                        text: parsedCode.text,
                        language: parsedCode.language,
                        sourceRange: parsedCode.sourceRange,
                        blockID: state.nextCodeBlockID(),
                        sectionID: activeSectionID
                    )
                )
                index = parsedCode.nextIndex
                continue
            }

            if let directive = parser.collectDirective(startingAt: index) {
                flushParagraph()
                switch directive.directive.kind {
                case .note:
                    let childBlocks = parseBlocks(
                        lines: directive.directive.bodyLines,
                        state: &state,
                        sections: &sections,
                        currentSectionID: activeSectionID,
                        recordsSections: false,
                        parsesHeadings: true
                    )
                    blocks.append(
                        parser.makeNoteBlock(
                            childBlocks: childBlocks,
                            sourceRange: directive.directive.sourceRange,
                            blockID: state.nextNoteBlockID(),
                            sectionID: activeSectionID
                        )
                    )
                case .canvas(let sceneID):
                    blocks.append(
                        parser.makeCanvasBlock(
                            sceneID: sceneID,
                            sourceRange: directive.directive.sourceRange,
                            blockID: state.nextCanvasBlockID(),
                            sectionID: activeSectionID
                        )
                    )
                }
                index = directive.nextIndex
                continue
            }

            if let parsedQuote = parser.collectQuoteLines(startingAt: index) {
                flushParagraph()
                let childBlocks = parseBlocks(
                    lines: parsedQuote.lines,
                    state: &state,
                    sections: &sections,
                    currentSectionID: activeSectionID,
                    recordsSections: false,
                    parsesHeadings: true
                )
                blocks.append(
                    parser.makeQuoteBlock(
                        childBlocks: childBlocks,
                        sourceRange: parsedQuote.sourceRange,
                        blockID: state.nextQuoteBlockID(),
                        sectionID: activeSectionID
                    )
                )
                index = parsedQuote.nextIndex
                continue
            }

            if let parsedList = parser.collectList(startingAt: index) {
                flushParagraph()
                let itemBlocks = parsedList.items.map { item in
                    parseBlocks(
                        lines: item.lines,
                        state: &state,
                        sections: &sections,
                        currentSectionID: activeSectionID,
                        recordsSections: false,
                        parsesHeadings: true
                    )
                }
                blocks.append(
                    parser.makeListBlock(
                        itemBlocks: itemBlocks,
                        ordered: parsedList.ordered,
                        sourceRange: parsedList.sourceRange,
                        blockID: state.nextListBlockID(),
                        sectionID: activeSectionID
                    )
                )
                index = parsedList.nextIndex
                continue
            }

            paragraphBuffer.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private func splitLines(_ text: String) -> [ASKMarkdownLine] {
        var lines: [ASKMarkdownLine] = []
        var current = ""
        var lineStartOffset = 0
        var offset = 0

        for character in text {
            if character == "\n" {
                lines.append(.init(raw: current, startOffset: lineStartOffset, endOffset: offset))
                current.removeAll(keepingCapacity: true)
                offset += 1
                lineStartOffset = offset
                continue
            }

            current.append(character)
            offset += 1
        }

        lines.append(.init(raw: current, startOffset: lineStartOffset, endOffset: offset))
        return lines
    }
}
