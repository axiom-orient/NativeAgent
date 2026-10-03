import XCTest
@testable import HTMLDocument

final class HTMLTokenizerTests: XCTestCase {
    func testTokenizesCommentsDoctypeAndTags() {
        var tokenizer = HTMLTokenizer("<!DOCTYPE html><!--hi--><p id='a'>Hello</p>")
        XCTAssertEqual(tokenizer.nextToken(), .doctype("html"))
        XCTAssertEqual(tokenizer.nextToken(), .comment("hi"))
        XCTAssertEqual(tokenizer.nextToken(), .startTag(.init(name: "p", attributes: [.init(name: "id", value: "a")], isSelfClosing: false)))
        XCTAssertEqual(tokenizer.nextToken(), .text("Hello"))
        XCTAssertEqual(tokenizer.nextToken(), .endTag("p"))
        XCTAssertNil(tokenizer.nextToken())
    }

    func testConsumesRawTextUntilMatchingClosingTag() {
        var tokenizer = HTMLTokenizer("if (x < y) {}</script><p>After</p>")
        let text = tokenizer.consumeRawText(untilClosingTagNamed: "script")
        XCTAssertEqual("if (x < y) {}", text)
        XCTAssertEqual(.startTag(.init(name: "p", attributes: [], isSelfClosing: false)), tokenizer.nextToken())
    }

    func testSkipsProcessingInstructions() {
        var tokenizer = HTMLTokenizer("<?import namespace='xss'?><p>Hello</p>")
        XCTAssertEqual(.startTag(.init(name: "p", attributes: [], isSelfClosing: false)), tokenizer.nextToken())
    }

    func testPreservesSlashInUnquotedAttributeValues() {
        var tokenizer = HTMLTokenizer("<a href=https://example.com/a/b data-test=post-item-123>Link</a>")
        XCTAssertEqual(
            .startTag(
                .init(
                    name: "a",
                    attributes: [
                        .init(name: "href", value: "https://example.com/a/b"),
                        .init(name: "data-test", value: "post-item-123")
                    ],
                    isSelfClosing: false
                )
            ),
            tokenizer.nextToken()
        )
    }

    func testRecognizesExplicitSelfClosingTagAfterUnquotedURL() {
        var tokenizer = HTMLTokenizer("<img src=https://example.com/a/b />")
        XCTAssertEqual(
            .startTag(
                .init(
                    name: "img",
                    attributes: [.init(name: "src", value: "https://example.com/a/b")],
                    isSelfClosing: true
                )
            ),
            tokenizer.nextToken()
        )
    }
}
