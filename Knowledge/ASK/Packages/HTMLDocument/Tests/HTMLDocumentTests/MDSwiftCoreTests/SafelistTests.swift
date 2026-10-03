    import XCTest
    @testable import HTMLDocument

    final class SafelistTests: XCTestCase {
        func testBasicPresetContainsAnchorRules() {
            let list = Safelist.basic()
            XCTAssertTrue(list.allowsTag("a"))
            XCTAssertTrue(list.allowsAttribute(tagName: "a", attributeName: "href"))
            XCTAssertEqual(["nofollow"], Set(list.enforcedAttributes(for: "a").values))
        }

        func testAddAttributesImplicitlyAddsTag() {
            let list = Safelist.none().addAttributes("p", "class")
            XCTAssertTrue(list.allowsTag("p"))
            XCTAssertTrue(list.allowsAttribute(tagName: "p", attributeName: "class"))
        }

        func testAllPseudoTagAppliesToEveryTag() {
            let list = Safelist.none().addAttributes(":all", "class")
            XCTAssertTrue(list.allowsAttribute(tagName: "p", attributeName: "class"))
            XCTAssertTrue(list.allowsAttribute(tagName: "a", attributeName: "class"))
        }
    }
