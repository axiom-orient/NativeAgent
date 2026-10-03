    import Foundation
    import XCTest
    @testable import HTMLDocument

    final class HTMLDataDecoderTests: XCTestCase {
        func testParsesUTF8Data() throws {
            let data = Data("<p>Hello</p>".utf8)
            let document = try HTMLDataDecoder.parseHTML(data)
            XCTAssertEqual("<p>Hello</p>", document.html)
        }

        func testParsesFileURL() throws {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let fileURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("html")
            try Data("<p>Hello file</p>".utf8).write(to: fileURL)

            defer {
                try? FileManager.default.removeItem(at: fileURL)
            }

            let document = try HTMLDataDecoder.parseHTML(fileAt: fileURL)
            XCTAssertEqual("<p>Hello file</p>", document.html)
        }

        func testRejectsNonFileURL() {
            XCTAssertThrowsError(try HTMLDataDecoder.parseHTML(fileAt: URL(string: "https://example.com")!))
        }
    }
