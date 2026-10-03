    import Foundation
    import XCTest
    @testable import HTMLDocument

    final class FacadeEndToEndTests: XCTestCase {
        func testParseSelectAndSerialize() throws {
            let document = try MDSwift.parseHTML("<html><body><p class='message'>Hello <b>Soup</b></p></body></html>")
            let values = try document.select("p.message > b").map(\.textContent)
            XCTAssertEqual(["Soup"], values)
            XCTAssertEqual("<html><body><p class=\"message\">Hello <b>Soup</b></p></body></html>", document.html)
        }

        func testCleanAndIsValid() throws {
            let dirty = "<script>alert(1)</script><p><a href='https://example.com'>Safe</a></p>"
            let clean = try MDSwift.clean(dirty, safelist: .basic())
            XCTAssertEqual("<p><a href=\"https://example.com\" rel=\"nofollow\">Safe</a></p>", clean)
            XCTAssertFalse(try MDSwift.isValid(dirty, safelist: .basic()))
        }

        func testParseHTMLDataThroughFacade() throws {
            let data = Data("<p>Data</p>".utf8)
            let document = try MDSwift.parseHTML(data)
            XCTAssertEqual("<p>Data</p>", document.html)
        }

        func testSelectsDeclarativeInteractiveHTMLMetadata() throws {
            let document = try MDSwift.parseHTML("""
            <!doctype html><html><head><title>Quiz</title></head><body>
            <button data-ama-action='answer' data-ama-id='choice-a'>A</button>
            <output data-ama-state='score'>0</output>
            </body></html>
            """)

            XCTAssertEqual(document.title, "Quiz")
            XCTAssertEqual(
                try document.select("[data-ama-action]").map { $0.attribute(named: "data-ama-action") },
                ["answer"]
            )
            XCTAssertEqual(
                try document.select("[data-ama-state]").map(\.normalizedText),
                ["0"]
            )
        }
    }
