import Testing
@testable import DocumentCore

@Test("Markdown compiler parses quotes, fenced code blocks, and lists")
func markdownCompilerParsesQuotesCodeBlocksAndLists() {
    let markdown = #"""
# Title

> Quote **bold**
> tail

```swift
let value = 1
print(value)
```

- first
- [cite](ask-cite://paper-1)

1. One
2. Two
"""#
    let document = ASKPageMarkdownCompiler().compile(
        markdown: markdown,
        documentID: .init("doc-blocks"),
        sourceID: .init("src-blocks")
    )

    #expect(document.sections.count == 1)
    #expect(document.blocks.count == 5)

    guard case let .quote(quote) = document.blocks[1].kind else {
        Issue.record("Expected quote block")
        return
    }
    #expect(quote.style == .quote)
    #expect(quote.runs.map(\.text).joined() == "Quote bold tail")
    #expect(quote.runs.contains { $0.emphasis.contains(.bold) })

    guard case let .code(code) = document.blocks[2].kind else {
        Issue.record("Expected code block")
        return
    }
    #expect(code.language == "swift")
    #expect(code.text == "let value = 1\nprint(value)")
    #expect(document.blocks[2].sourceAnchor?.range?.length == code.text.count)

    guard case let .list(unorderedList) = document.blocks[3].kind else {
        Issue.record("Expected unordered list block")
        return
    }
    #expect(unorderedList.ordered == false)
    #expect(unorderedList.items.count == 2)
    #expect(unorderedList.items[0].map(\.text).joined() == "first")
    #expect(unorderedList.items[1].first?.semanticRole == .citation(identifier: "paper-1"))

    guard case let .list(orderedList) = document.blocks[4].kind else {
        Issue.record("Expected ordered list block")
        return
    }
    #expect(orderedList.ordered == true)
    #expect(orderedList.items.count == 2)
    #expect(orderedList.items[0].map(\.text).joined() == "One")
    #expect(orderedList.items[1].map(\.text).joined() == "Two")
}


@Test("Markdown compiler parses .note and .canvas directives with nested CommonMark containers")
func markdownCompilerParsesNoteCanvasAndNestedCommonMark() {
    let markdown = #"""
# Title

:::.note
Lead paragraph

> quoted
> - nested item

- outer
  - inner
  > inline quote

```swift
let x = 1
```
:::

:::.canvas scene-main
:::
"""#

    let document = ASKPageMarkdownCompiler().compile(
        markdown: markdown,
        documentID: .init("doc-note-canvas"),
        sourceID: .init("src-note-canvas")
    )

    #expect(document.sections.count == 1)
    #expect(document.blocks.count == 3)

    guard case let .note(note) = document.blocks[1].kind else {
        Issue.record("Expected note block")
        return
    }

    let noteText = note.runs.map(\.text).joined()
    #expect(note.style == .note)
    #expect(noteText.contains("Lead paragraph"))
    #expect(noteText.contains("> quoted"))
    #expect(noteText.contains("> - nested item"))
    #expect(noteText.contains("- outer"))
    #expect(noteText.contains("  - inner"))
    #expect(noteText.contains("  > inline quote"))
    #expect(noteText.contains("let x = 1"))

    guard case let .canvas(canvas) = document.blocks[2].kind else {
        Issue.record("Expected canvas block")
        return
    }

    #expect(canvas.sceneID == .init("scene-main"))
    #expect(document.blocks[2].sourceAnchor?.range != nil)
}
