
struct ASKPretextLineBreaker {
    let text: String
    let pointSize: Double
    let lineHeight: Double

    private var characterAdvance: Double {
        max(pointSize * 0.6, 1)
    }

    func layoutLines(maxWidth: Double) -> [ASKLaidOutLine] {
        var lines: [ASKLaidOutLine] = []
        var offset = 0
        var originY = 0.0

        while let fragment = layoutFragment(maxWidth: maxWidth, offset: offset, originX: 0, originY: originY) {
            lines.append(fragment.line)
            offset = fragment.nextOffset
            originY += lineHeight
            if offset >= text.count { break }
        }

        return lines
    }

    func layoutSingleFragment(maxWidth: Double, offset: Int, originX: Double, originY: Double) -> ASKLaidOutLine? {
        layoutFragment(maxWidth: maxWidth, offset: offset, originX: originX, originY: originY)?.line
    }

    func nextOffset(after line: ASKLaidOutLine) -> Int {
        let characters = Array(text)
        var offset = line.sourceRange.end
        if offset < characters.count, characters[offset] == "\n" {
            offset += 1
        } else {
            while offset < characters.count, characters[offset] == " " {
                offset += 1
            }
        }
        return offset
    }

    private func layoutFragment(maxWidth: Double, offset: Int, originX: Double, originY: Double) -> ASKPretextFragment? {
        guard offset < text.count else {
            return nil
        }
        let characters = Array(text)
        let capacity = max(Int(maxWidth / characterAdvance), 1)
        var end = min(offset + capacity, characters.count)

        if let forcedBreak = characters[offset..<min(offset + capacity, characters.count)].firstIndex(of: "\n") {
            end = forcedBreak
        } else if end < characters.count {
            if let whitespace = characters[offset..<end].lastIndex(where: { $0 == " " || $0 == "\t" }) {
                end = whitespace == offset ? min(offset + capacity, characters.count) : whitespace
            }
        }

        while end > offset, characters[end - 1] == " " {
            end -= 1
        }

        if end == offset {
            end = min(offset + capacity, characters.count)
        }

        let lineText = String(characters[offset..<end])
        let width = Double(lineText.count) * characterAdvance
        let line = ASKLaidOutLine(
            text: lineText,
            width: width,
            originX: originX,
            originY: originY,
            sourceRange: .init(start: offset, end: end)
        )
        return ASKPretextFragment(line: line, nextOffset: nextOffset(after: line))
    }
}

private struct ASKPretextFragment {
    let line: ASKLaidOutLine
    let nextOffset: Int
}
