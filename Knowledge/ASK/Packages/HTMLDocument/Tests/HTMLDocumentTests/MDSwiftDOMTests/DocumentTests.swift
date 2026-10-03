    import XCTest
    @testable import HTMLDocument

    final class DocumentTests: XCTestCase {
        func testParseSerializeRoundTripForSimpleDocument() throws {
            let document = try Soup.parseHTML("<html><head><title>Example</title></head><body><p>Hello <b>world</b></p></body></html>")
            XCTAssertEqual("<html><head><title>Example</title></head><body><p>Hello <b>world</b></p></body></html>", document.html)
            XCTAssertEqual("Example", document.title)
            XCTAssertEqual("Hello world", document.body?.normalizedText)
        }

        func testImplicitTableContainerSerializesDeterministically() throws {
            let document = try Soup.parseHTML("<table><tr><td>One<td>Two</tr></table>")
            XCTAssertEqual("<table><tbody><tr><td>One</td><td>Two</td></tr></tbody></table>", document.html)
        }

        func testDocumentCleansWithSafelist() throws {
            let document = try Soup.parseHTML("<script>alert(1)</script><p>Hello <b>there</b></p>")
            let clean = document.cleaned(with: .simpleText())
            XCTAssertEqual("Hello <b>there</b>", clean.html)
        }
    }
