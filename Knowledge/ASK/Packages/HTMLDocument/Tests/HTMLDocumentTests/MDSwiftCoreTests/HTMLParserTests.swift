    import XCTest
    @testable import HTMLDocument

    private struct RecorderSink: HTMLTreeSink {
        typealias Output = [String]
        var events: [String] = []

        mutating func beginDocument() throws {}
        mutating func insertDoctype(_ name: String) throws { events.append("doctype:\(name)") }
        mutating func insertComment(_ text: String) throws { events.append("comment:\(text)") }
        mutating func insertText(_ text: String) throws { events.append("text:\(text)") }
        mutating func insertData(_ text: String) throws { events.append("data:\(text)") }
        mutating func insertStartTag(_ tag: HTMLStartTag) throws { events.append("start:\(tag.name)") }
        mutating func insertEndTag(named name: String) throws { events.append("end:\(name)") }
        mutating func finishDocument() throws -> [String] { events }
    }

    final class HTMLParserTests: XCTestCase {
        func testNormalizesAttributesAndDecodesEntities() throws {
            let events = try HTMLParser.parse(
                "<P ID='a' DATA-V='A&amp;B'>Hello &amp; world</P>",
                into: RecorderSink()
            )
            XCTAssertEqual(
                ["start:p", "text:Hello & world", "end:p"],
                events.filter { $0.hasPrefix("start") || $0.hasPrefix("text") || $0.hasPrefix("end") }
            )
        }

        func testAutoClosesParagraphs() throws {
            let events = try HTMLParser.parse("<p>One<p>Two", into: RecorderSink())
            XCTAssertEqual(["start:p", "text:One", "end:p", "start:p", "text:Two", "end:p"], events)
        }

        func testTreatsScriptAsRawText() throws {
            let events = try HTMLParser.parse("<script>if (x < y) { alert('&'); }</script>", into: RecorderSink())
            XCTAssertEqual(["start:script", "data:if (x < y) { alert('&'); }", "end:script"], events)
        }

        func testParsesUTF8BytesInCore() throws {
            let events = try HTMLParser.parse(
                utf8: Array("<p>Hello</p>".utf8),
                into: RecorderSink()
            )
            XCTAssertEqual(["start:p", "text:Hello", "end:p"], events)
        }

        func testInsertsImplicitTBodyForRows() throws {
            let events = try HTMLParser.parse("<table><tr><td>One<td>Two</tr></table>", into: RecorderSink())
            XCTAssertEqual(
                ["start:table", "start:tbody", "start:tr", "start:td", "text:One", "end:td", "start:td", "text:Two", "end:td", "end:tr", "end:tbody", "end:table"],
                events
            )
        }
    }
