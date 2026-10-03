import Foundation

struct ASKMarkdownBlockParser {
    let lines: [ASKMarkdownLine]
    let sourceID: ASKPageSourceID

    private let blockProjection = ASKMarkdownBlockProjection()

    func parseCodeBlock(startingAt startIndex: Int) -> (text: String, language: String?, sourceRange: ASKPageSourceRange, nextIndex: Int)? {
        guard let fence = parseOpeningCodeFence(line: lines[startIndex]) else {
            return nil
        }

        var codeLines: [ASKMarkdownLine] = []
        var index = startIndex + 1
        while index < lines.count {
            let line = lines[index]
            if isClosingCodeFence(line: line, matching: fence) {
                let sourceRange = codeSourceRange(codeLines: codeLines, openingLine: lines[startIndex])
                return (codeLines.map(\.raw).joined(separator: "\n"), fence.language, sourceRange, index + 1)
            }
            codeLines.append(line)
            index += 1
        }

        let sourceRange = codeSourceRange(codeLines: codeLines, openingLine: lines[startIndex])
        return (codeLines.map(\.raw).joined(separator: "\n"), fence.language, sourceRange, lines.count)
    }

    func collectQuoteLines(startingAt startIndex: Int) -> (lines: [ASKMarkdownLine], sourceRange: ASKPageSourceRange, nextIndex: Int)? {
        guard let firstLine = strippedQuoteLine(from: lines[startIndex]) else {
            return nil
        }

        var strippedLines: [ASKMarkdownLine] = [firstLine]
        let rangeStart = firstLine.startOffset
        var rangeEnd = firstLine.endOffset
        var index = startIndex + 1

        while index < lines.count {
            guard let stripped = strippedQuoteLine(from: lines[index]) else {
                break
            }
            strippedLines.append(stripped)
            rangeEnd = stripped.endOffset
            index += 1
        }

        return (strippedLines, .init(start: rangeStart, end: rangeEnd), index)
    }

    func collectDirective(startingAt startIndex: Int) -> (directive: ASKMarkdownCollectedDirective, nextIndex: Int)? {
        guard let opening = parseDirectiveOpening(line: lines[startIndex]) else {
            return nil
        }

        var bodyLines: [ASKMarkdownLine] = []
        var rangeEnd = lines[startIndex].endOffset
        var depth = 1
        var index = startIndex + 1

        while index < lines.count {
            let line = lines[index]
            if parseDirectiveOpening(line: line) != nil {
                depth += 1
                bodyLines.append(line)
                rangeEnd = line.endOffset
                index += 1
                continue
            }
            if isDirectiveClosing(line: line, minimumFenceLength: opening.fenceLength) {
                depth -= 1
                if depth == 0 {
                    return (
                        ASKMarkdownCollectedDirective(
                            kind: opening.kind,
                            bodyLines: bodyLines,
                            sourceRange: .init(start: opening.contentStartOffset, end: rangeEnd)
                        ),
                        index + 1
                    )
                }
            }
            bodyLines.append(line)
            rangeEnd = line.endOffset
            index += 1
        }

        return (
            ASKMarkdownCollectedDirective(
                kind: opening.kind,
                bodyLines: bodyLines,
                sourceRange: .init(start: opening.contentStartOffset, end: rangeEnd)
            ),
            lines.count
        )
    }

    func collectList(startingAt startIndex: Int) -> (ordered: Bool, items: [ASKMarkdownCollectedListItem], sourceRange: ASKPageSourceRange, nextIndex: Int)? {
        guard let firstMarker = parseListMarker(line: lines[startIndex]) else {
            return nil
        }

        var items: [ASKMarkdownCollectedListItem] = []
        var index = startIndex
        let rangeStart = firstMarker.contentLine.startOffset
        var rangeEnd = firstMarker.contentLine.endOffset

        while index < lines.count {
            guard let marker = parseListMarker(line: lines[index]),
                  marker.ordered == firstMarker.ordered,
                  marker.indent == firstMarker.indent
            else {
                break
            }

            var itemLines: [ASKMarkdownLine] = [marker.contentLine]
            rangeEnd = marker.contentLine.endOffset
            index += 1

            while index < lines.count {
                let line = lines[index]

                if let nextMarker = parseListMarker(line: line),
                   nextMarker.ordered == firstMarker.ordered,
                   nextMarker.indent == firstMarker.indent {
                    break
                }

                if line.trimmed.isEmpty {
                    itemLines.append(.init(raw: "", startOffset: line.endOffset, endOffset: line.endOffset))
                    rangeEnd = line.endOffset
                    index += 1
                    continue
                }

                let requiredIndent = marker.contentPrefixWidth
                if line.leadingSpaces() >= requiredIndent {
                    let stripped = line.droppingPrefix(requiredIndent)
                    itemLines.append(stripped)
                    rangeEnd = stripped.endOffset
                    index += 1
                    continue
                }

                break
            }

            let itemRange = ASKPageSourceRange(start: itemLines.first?.startOffset ?? marker.contentLine.startOffset, end: rangeEnd)
            items.append(.init(lines: itemLines, sourceRange: itemRange))
        }

        return (firstMarker.ordered, items, .init(start: rangeStart, end: rangeEnd), index)
    }

    func makeParagraphBlock(
        lines: [ASKMarkdownLine],
        blockID: ASKPageBlockID,
        sectionID: ASKPageSectionID?
    ) -> ASKPageBlock {
        let runs = joinParsedInlineRuns(from: lines, separator: " ")
        let blockRange = ASKPageSourceRange(start: lines[0].startOffset, end: lines[lines.count - 1].endOffset)
        return ASKPageBlock(
            id: blockID,
            kind: .paragraph(.init(runs: runs, style: .body)),
            sectionID: sectionID,
            sourceAnchor: .init(sourceID: sourceID, range: blockRange)
        )
    }

    func makeHeadingBlock(_ heading: ASKMarkdownHeading, blockID: ASKPageBlockID, sectionID: ASKPageSectionID?) -> ASKPageBlock {
        ASKPageBlock(
            id: blockID,
            kind: .heading(.init(runs: heading.runs, style: .heading)),
            sectionID: sectionID,
            sourceAnchor: .init(sourceID: sourceID, fragment: heading.fragment, range: heading.sourceRange)
        )
    }

    func makeCodeBlock(
        text: String,
        language: String?,
        sourceRange: ASKPageSourceRange,
        blockID: ASKPageBlockID,
        sectionID: ASKPageSectionID?
    ) -> ASKPageBlock {
        ASKPageBlock(
            id: blockID,
            kind: .code(.init(language: language, text: text)),
            sectionID: sectionID,
            sourceAnchor: .init(sourceID: sourceID, range: sourceRange)
        )
    }

    func makeQuoteBlock(
        childBlocks: [ASKPageBlock],
        sourceRange: ASKPageSourceRange,
        blockID: ASKPageBlockID,
        sectionID: ASKPageSectionID?
    ) -> ASKPageBlock {
        ASKPageBlock(
            id: blockID,
            kind: .quote(.init(runs: blockProjection.flattenBlocksToRuns(childBlocks, blockSeparator: "\n\n"), style: .quote)),
            sectionID: sectionID,
            sourceAnchor: .init(sourceID: sourceID, range: sourceRange)
        )
    }

    func makeNoteBlock(
        childBlocks: [ASKPageBlock],
        sourceRange: ASKPageSourceRange,
        blockID: ASKPageBlockID,
        sectionID: ASKPageSectionID?
    ) -> ASKPageBlock {
        ASKPageBlock(
            id: blockID,
            kind: .note(.init(runs: blockProjection.flattenBlocksToRuns(childBlocks, blockSeparator: "\n\n"), style: .note)),
            sectionID: sectionID,
            sourceAnchor: .init(sourceID: sourceID, range: sourceRange)
        )
    }

    func makeCanvasBlock(
        sceneID: ASKPageCanvasSceneID,
        sourceRange: ASKPageSourceRange,
        blockID: ASKPageBlockID,
        sectionID: ASKPageSectionID?
    ) -> ASKPageBlock {
        ASKPageBlock(
            id: blockID,
            kind: .canvas(.init(sceneID: sceneID)),
            sectionID: sectionID,
            sourceAnchor: .init(sourceID: sourceID, range: sourceRange)
        )
    }

    func makeListBlock(
        itemBlocks: [[ASKPageBlock]],
        ordered: Bool,
        sourceRange: ASKPageSourceRange,
        blockID: ASKPageBlockID,
        sectionID: ASKPageSectionID?
    ) -> ASKPageBlock {
        let items = itemBlocks.map { blocks in
            blockProjection.flattenListItemBlocksToRuns(blocks)
        }
        return ASKPageBlock(
            id: blockID,
            kind: .list(.init(ordered: ordered, items: items)),
            sectionID: sectionID,
            sourceAnchor: .init(sourceID: sourceID, range: sourceRange)
        )
    }

    func parseHeading(line: ASKMarkdownLine) -> ASKMarkdownHeading? {
        let characters = Array(line.raw)
        var level = 0
        while level < characters.count, characters[level] == "#" {
            level += 1
        }

        guard level > 0, level < characters.count, characters[level] == " " else {
            return nil
        }

        let contentStart = level + 1
        let content = String(characters[contentStart...])
        let sourceRange = ASKPageSourceRange(
            start: line.startOffset + contentStart,
            end: line.endOffset
        )
        let runs = ASKMarkdownInlineParser(
            text: content,
            baseOffset: line.startOffset + contentStart,
            sourceID: sourceID
        ).parse()
        let title = runs.map(\.text).joined()
        let fragment = "#" + title.lowercased().replacingOccurrences(of: " ", with: "-")
        return ASKMarkdownHeading(level: level, text: title, fragment: fragment, runs: runs, sourceRange: sourceRange)
    }

    private func parseOpeningCodeFence(line: ASKMarkdownLine) -> ASKMarkdownCodeFence? {
        let characters = Array(line.raw)
        var index = 0
        while index < characters.count, index < 3, characters[index] == " " {
            index += 1
        }
        guard index < characters.count else {
            return nil
        }

        let fenceCharacter = characters[index]
        guard fenceCharacter == "`" || fenceCharacter == "~" else {
            return nil
        }

        var fenceLength = 0
        while index + fenceLength < characters.count, characters[index + fenceLength] == fenceCharacter {
            fenceLength += 1
        }
        guard fenceLength >= 3 else {
            return nil
        }

        let infoStart = index + fenceLength
        let info = infoStart < characters.count
            ? String(characters[infoStart...]).trimmingCharacters(in: .whitespaces)
            : ""
        let language = info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        return ASKMarkdownCodeFence(character: fenceCharacter, length: fenceLength, language: language)
    }

    private func isClosingCodeFence(line: ASKMarkdownLine, matching fence: ASKMarkdownCodeFence) -> Bool {
        let characters = Array(line.raw)
        var index = 0
        while index < characters.count, index < 3, characters[index] == " " {
            index += 1
        }
        guard index < characters.count else {
            return false
        }

        var fenceLength = 0
        while index + fenceLength < characters.count, characters[index + fenceLength] == fence.character {
            fenceLength += 1
        }
        guard fenceLength >= fence.length else {
            return false
        }

        let trailing = String(characters.dropFirst(index + fenceLength))
        return trailing.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func codeSourceRange(codeLines: [ASKMarkdownLine], openingLine: ASKMarkdownLine) -> ASKPageSourceRange {
        let rangeStart = codeLines.first?.startOffset ?? openingLine.endOffset
        let rangeEnd = codeLines.last?.endOffset ?? rangeStart
        return .init(start: rangeStart, end: rangeEnd)
    }

    private func strippedQuoteLine(from line: ASKMarkdownLine) -> ASKMarkdownLine? {
        let characters = Array(line.raw)
        var index = 0
        while index < characters.count, index < 3, characters[index] == " " {
            index += 1
        }
        guard index < characters.count, characters[index] == ">" else {
            return nil
        }
        index += 1
        if index < characters.count, characters[index] == " " {
            index += 1
        }
        return line.droppingPrefix(index)
    }

    private func parseListMarker(line: ASKMarkdownLine) -> (ordered: Bool, indent: Int, contentPrefixWidth: Int, contentLine: ASKMarkdownLine)? {
        let characters = Array(line.raw)
        let indent = line.leadingSpaces(limit: 4)
        let index = indent
        guard index < characters.count else {
            return nil
        }

        if ["-", "*", "+"].contains(characters[index]), index + 1 < characters.count, characters[index + 1] == " " {
            let contentPrefixWidth = index + 2
            return (false, indent, contentPrefixWidth, line.droppingPrefix(contentPrefixWidth))
        }

        var markerEnd = index
        while markerEnd < characters.count, characters[markerEnd].isNumber {
            markerEnd += 1
        }
        guard markerEnd > index,
              markerEnd + 1 < characters.count,
              (characters[markerEnd] == "." || characters[markerEnd] == ")"),
              characters[markerEnd + 1] == " "
        else {
            return nil
        }

        let contentPrefixWidth = markerEnd + 2
        return (true, indent, contentPrefixWidth, line.droppingPrefix(contentPrefixWidth))
    }

    private func parseDirectiveOpening(line: ASKMarkdownLine) -> (kind: ASKMarkdownDirectiveKind, fenceLength: Int, contentStartOffset: Int)? {
        let characters = Array(line.raw)
        var index = 0
        while index < characters.count, index < 3, characters[index] == " " {
            index += 1
        }
        var fenceLength = 0
        while index + fenceLength < characters.count, characters[index + fenceLength] == ":" {
            fenceLength += 1
        }
        guard fenceLength >= 3 else {
            return nil
        }

        let remainderStart = index + fenceLength
        guard remainderStart < characters.count else {
            return nil
        }
        let remainder = String(characters[remainderStart...]).trimmingCharacters(in: .whitespaces)
        guard remainder.hasPrefix(".") else {
            return nil
        }

        if remainder.hasPrefix(".note") {
            return (.note, fenceLength, line.endOffset)
        }
        if remainder.hasPrefix(".canvas") {
            let sceneSpec = remainder.dropFirst(".canvas".count).trimmingCharacters(in: .whitespaces)
            guard let sceneID = parseCanvasSceneID(String(sceneSpec)) else {
                return nil
            }
            return (.canvas(sceneID: sceneID), fenceLength, line.startOffset + remainderStart + ".canvas".count + sceneSpec.leadingWhitespaceCount)
        }
        return nil
    }

    private func isDirectiveClosing(line: ASKMarkdownLine, minimumFenceLength: Int) -> Bool {
        let characters = Array(line.raw)
        var index = 0
        while index < characters.count, index < 3, characters[index] == " " {
            index += 1
        }
        var fenceLength = 0
        while index + fenceLength < characters.count, characters[index + fenceLength] == ":" {
            fenceLength += 1
        }
        guard fenceLength >= minimumFenceLength else {
            return false
        }
        let trailing = String(characters.dropFirst(index + fenceLength))
        return trailing.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func parseCanvasSceneID(_ raw: String) -> ASKPageCanvasSceneID? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let equalIndex = trimmed.firstIndex(of: "=") {
            let key = trimmed[..<equalIndex].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equalIndex)...].trimmingCharacters(in: .whitespaces)
            guard key == "scene", !value.isEmpty else {
                return nil
            }
            return ASKPageCanvasSceneID(value)
        }

        return ASKPageCanvasSceneID(trimmed)
    }

    private func joinParsedInlineRuns(from lines: [ASKMarkdownLine], separator: String) -> [ASKPageInlineRun] {
        var runs: [ASKPageInlineRun] = []
        for (index, line) in lines.enumerated() {
            let parsedRuns = ASKMarkdownInlineParser(
                text: line.raw,
                baseOffset: line.startOffset,
                sourceID: sourceID
            ).parse()
            runs.append(contentsOf: parsedRuns)
            if index < lines.count - 1 {
                runs.append(.init(text: separator))
            }
        }
        return runs
    }


}

private extension String {
    var leadingWhitespaceCount: Int {
        prefix(while: { $0 == " " }).count
    }
}
