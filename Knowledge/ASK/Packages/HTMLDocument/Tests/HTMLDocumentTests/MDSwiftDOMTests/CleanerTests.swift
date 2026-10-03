import XCTest
@testable import HTMLDocument

final class CleanerTests: XCTestCase {
    func testSimpleTextPresetDropsLinksAndPreservesBold() throws {
        let document = try Soup.parseHTML("<div><p><a href='http://evil.com'>Hello <b>there</b>!</a></p></div>")
        let clean = HTMLCleaner(.simpleText()).clean(document)
        XCTAssertEqual("Hello <b>there</b>!", clean.html)
    }

    func testBasicPresetEnforcesRelAndDropsJavascriptHref() throws {
        let document = try Soup.parseHTML("<p><a href='javascript:alert(1)'>Bad</a> <a href='https://example.com'>Good</a></p>")
        let clean = HTMLCleaner(.basic()).clean(document)
        XCTAssertEqual("<p><a rel=\"nofollow\">Bad</a> <a href=\"https://example.com\" rel=\"nofollow\">Good</a></p>", clean.html)
    }

    func testBasicWithImagesAllowsHTTPImagesOnly() throws {
        let document = try Soup.parseHTML("<p><img src='http://example.com/x.png' alt='Image'></p><p><img src='ftp://bad'></p>")
        let clean = HTMLCleaner(.basicWithImages()).clean(document)
        XCTAssertEqual("<p><img src=\"http://example.com/x.png\" alt=\"Image\" /></p><p><img /></p>", clean.html)
    }

    func testRelativeLinksResolveOnlyForSlashPrefixedURLs() throws {
        let document = try Soup.parseHTML("<a href='/foo'>Link</a><img src='/bar'><a href='article.html'>Article</a>")
        let clean = HTMLCleaner(.basicWithImages()).clean(document, baseURI: "http://example.com/base/")
        XCTAssertEqual("<a href=\"http://example.com/foo\" rel=\"nofollow\">Link</a><img src=\"http://example.com/bar\" /><a href=\"article.html\" rel=\"nofollow\">Article</a>", clean.html)
    }

    func testResolvedSlashLinksRejectDisallowedBaseSchemes() throws {
        let document = try Soup.parseHTML("<a href='/foo'>Link</a><img src='/bar'>")

        for baseURI in ["javascript://attacker.example/base/", "ftp://attacker.example/"] {
            let clean = HTMLCleaner(.basicWithImages()).clean(document, baseURI: baseURI)
            XCTAssertEqual("<a rel=\"nofollow\">Link</a><img />", clean.html, baseURI)
        }
    }

    func testMalformedBaseKeepsExistingRelativeFallback() throws {
        let document = try Soup.parseHTML("<a href='/foo'>Link</a><img src='/bar'>")
        let clean = HTMLCleaner(.basicWithImages()).clean(document, baseURI: "not-a-base")
        XCTAssertEqual("<a href=\"/foo\" rel=\"nofollow\">Link</a><img src=\"/bar\" />", clean.html)
    }

    func testAllowedResolvedBaseSchemeRemainsAcceptedCaseInsensitively() throws {
        let document = try Soup.parseHTML("<a href='/foo'>Link</a><img src='/bar'>")
        let clean = HTMLCleaner(.basicWithImages()).clean(document, baseURI: "HtTpS://example.com/base/")
        XCTAssertEqual("<a href=\"HtTpS://example.com/foo\" rel=\"nofollow\">Link</a><img src=\"HtTpS://example.com/bar\" />", clean.html)
    }

    func testPreserveRelativeLinksKeepsSlashPrefixedURLs() throws {
        let document = try Soup.parseHTML("<a href='/foo'>Link</a><img src='/bar'><img src='javascript:alert()'>")
        let clean = HTMLCleaner(.basicWithImages().preserveRelativeLinks(true)).clean(document, baseURI: "http://example.com/")
        XCTAssertEqual("<a href=\"/foo\" rel=\"nofollow\">Link</a><img src=\"/bar\" /><img />", clean.html)
    }

    /// Browsers strip C0 controls before resolving a scheme, so a control character
    /// inside the scheme must not downgrade the value to a "relative URL" and survive.
    func testControlCharactersInSchemeDoNotBypassProtocolSafelist() throws {
        let payloads = [
            ("tab", "java&#9;script:alert(1)"),
            ("line feed", "java&#10;script:alert(1)"),
            ("carriage return", "java&#13;script:alert(1)"),
            ("null", "java&#0;script:alert(1)"),
            ("space", "java script:alert(1)"),
        ]

        for (name, payload) in payloads {
            let document = try Soup.parseHTML("<a href=\"\(payload)\">x</a><img src=\"\(payload)\">")
            let clean = HTMLCleaner(.basicWithImages()).clean(document)
            XCTAssertEqual(
                "<a rel=\"nofollow\">x</a><img />",
                clean.html,
                "\(name) in a scheme must be discarded"
            )
        }
    }

    func testMalformedSchemeIsRejectedInsteadOfTreatedAsRelative() throws {
        let document = try Soup.parseHTML("<a href='wat?:evil'>x</a><blockquote cite='java&#9;script:1'>y</blockquote>")
        let clean = HTMLCleaner(.basicWithImages()).clean(document)
        XCTAssertEqual("<a href=\"wat?:evil\" rel=\"nofollow\">x</a><blockquote>y</blockquote>", clean.html)
    }

    func testColonAfterPathSeparatorRemainsARelativeURL() throws {
        let document = try Soup.parseHTML("<a href='docs/a:b.html'>x</a>")
        let clean = HTMLCleaner(.basicWithImages()).clean(document)
        XCTAssertEqual("<a href=\"docs/a:b.html\" rel=\"nofollow\">x</a>", clean.html)
    }

    func testNonASCIISchemeIsNotAcceptedAsAllowedProtocol() throws {
        // Cyrillic "ј" (U+0458) looks like ASCII "j" but must not satisfy the scheme grammar.
        let document = try Soup.parseHTML("<a href='\u{0458}avascript:alert(1)'>x</a>")
        let clean = HTMLCleaner(.basicWithImages()).clean(document)
        XCTAssertEqual("<a rel=\"nofollow\">x</a>", clean.html)
    }

    func testWhitelistNoneNormalizesNBSPToSpace() throws {
        let document = try Soup.parseHTML("&nbsp;")
        let clean = HTMLCleaner(.none()).clean(document)
        XCTAssertEqual(" ", clean.html)
    }

    func testIsValidReflectsSanitizerChanges() throws {
        let ok = try Soup.parseHTML("<p>Test <b><a href='https://example.com'>OK</a></b></p>")
        let nok = try Soup.parseHTML("<p><script></script>Not <b>OK</b></p>")

        XCTAssertTrue(HTMLCleaner(.basic()).isValid(ok))
        XCTAssertFalse(HTMLCleaner(.basic()).isValid(nok))
    }

    func testIsValidHonorsSeparateHeadAndBodySafelists() throws {
        let dirty = try Soup.parseHTML("<html><head><title>Hello</title></head><body><p>Hey!</p></body></html>")
        let cleaner = HTMLCleaner(headSafelist: .none().addTags("title"), bodySafelist: .relaxed())

        XCTAssertTrue(cleaner.isValid(dirty))
    }

    func testSeparateHeadAndBodySafelists() throws {
        let dirty = try Soup.parseHTML("<html><head><title>Hello</title><style>body{}</style></head><body><p>Hey!</p></body></html>")
        let clean = HTMLCleaner(headSafelist: .none().addTags("title"), bodySafelist: .relaxed()).clean(dirty)
        XCTAssertEqual("<html><head><title>Hello</title></head><body><p>Hey!</p></body></html>", clean.html)
    }
}
