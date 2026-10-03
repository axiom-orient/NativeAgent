import Foundation

struct ASKMarkdownLine {
    let raw: String
    let startOffset: Int
    let endOffset: Int

    var trimmed: String {
        raw.trimmingCharacters(in: .whitespaces)
    }

    func leadingSpaces(limit: Int? = nil) -> Int {
        let characters = Array(raw)
        var count = 0
        while count < characters.count, characters[count] == " ", limit.map({ count < $0 }) ?? true {
            count += 1
        }
        return count
    }

    func droppingPrefix(_ count: Int) -> ASKMarkdownLine {
        guard count > 0 else {
            return self
        }
        let characters = Array(raw)
        guard count < characters.count else {
            return ASKMarkdownLine(raw: "", startOffset: endOffset, endOffset: endOffset)
        }
        return ASKMarkdownLine(
            raw: String(characters.dropFirst(count)),
            startOffset: startOffset + count,
            endOffset: endOffset
        )
    }
}

struct ASKMarkdownHeading {
    let level: Int
    let text: String
    let fragment: String
    let runs: [ASKPageInlineRun]
    let sourceRange: ASKPageSourceRange
}

struct ASKMarkdownCodeFence {
    let character: Character
    let length: Int
    let language: String?
}

struct ASKMarkdownListMarker {
    let ordered: Bool
    let indent: Int
    let contentPrefixWidth: Int
}

struct ASKMarkdownCollectedListItem {
    let lines: [ASKMarkdownLine]
    let sourceRange: ASKPageSourceRange
}

struct ASKMarkdownCollectedDirective {
    let kind: ASKMarkdownDirectiveKind
    let bodyLines: [ASKMarkdownLine]
    let sourceRange: ASKPageSourceRange
}

enum ASKMarkdownDirectiveKind {
    case note
    case canvas(sceneID: ASKPageCanvasSceneID)
}

struct ASKMarkdownParserState {
    var sectionCount = 0
    var headingCount = 0
    var paragraphCount = 0
    var quoteCount = 0
    var codeCount = 0
    var listCount = 0
    var noteCount = 0
    var canvasCount = 0

    mutating func nextSectionID() -> ASKPageSectionID {
        sectionCount += 1
        return ASKPageSectionID("section-\(sectionCount)")
    }

    mutating func nextHeadingBlockID() -> ASKPageBlockID {
        headingCount += 1
        return ASKPageBlockID("heading-\(headingCount)")
    }

    mutating func nextParagraphBlockID() -> ASKPageBlockID {
        paragraphCount += 1
        return ASKPageBlockID("paragraph-\(paragraphCount)")
    }

    mutating func nextQuoteBlockID() -> ASKPageBlockID {
        quoteCount += 1
        return ASKPageBlockID("quote-\(quoteCount)")
    }

    mutating func nextCodeBlockID() -> ASKPageBlockID {
        codeCount += 1
        return ASKPageBlockID("code-\(codeCount)")
    }

    mutating func nextListBlockID() -> ASKPageBlockID {
        listCount += 1
        return ASKPageBlockID("list-\(listCount)")
    }

    mutating func nextNoteBlockID() -> ASKPageBlockID {
        noteCount += 1
        return ASKPageBlockID("note-\(noteCount)")
    }

    mutating func nextCanvasBlockID() -> ASKPageBlockID {
        canvasCount += 1
        return ASKPageBlockID("canvas-\(canvasCount)")
    }
}
