import XCTest
@testable import HTMLDocument

final class CSSSelectorParserTests: XCTestCase {
    func testParsesTagClassAndChildCombinator() throws {
        let group = try CSSSelectorParser.parse("div.article > p.lead")
        XCTAssertEqual(1, group.selectors.count)
        XCTAssertEqual(2, group.selectors[0].steps.count)
    }

    func testParsesGroupedSelectors() throws {
        let group = try CSSSelectorParser.parse("a[href], span.note")
        XCTAssertEqual(2, group.selectors.count)
    }

    func testParsesRealWorldCombinators() throws {
        let group = try CSSSelectorParser.parse("tr.athing + tr .subtext, section.card ~ section.card a")
        XCTAssertEqual(2, group.selectors.count)
        XCTAssertEqual(.adjacentSibling, group.selectors[0].steps[1].combinator)
        XCTAssertEqual(.generalSibling, group.selectors[1].steps[1].combinator)
    }

    func testParsesAttributePrefixSuffixAndContainsOperators() throws {
        let group = try CSSSelectorParser.parse("[data-test^=post-item-], [data-test$=tagline], [data-test*=post-name-]")
        XCTAssertEqual(3, group.selectors.count)
    }

    func testParsesRelativeHasContainsOwnAndStructuralSelectors() throws {
        let group = try CSSSelectorParser.parse("section:has(> h2:containsOwn(Community highlights)) article:nth-of-type(2)")
        XCTAssertEqual(1, group.selectors.count)
        XCTAssertEqual(2, group.selectors[0].steps.count)

        let firstCompound = group.selectors[0].steps[0].compound.components
        guard case .has(let relativeGroup) = firstCompound[1] else {
            return XCTFail("expected :has selector")
        }
        XCTAssertEqual(.child, relativeGroup.selectors[0].steps.first?.combinator)
    }

    func testParsesRelativeSiblingHasSelectors() throws {
        let group = try CSSSelectorParser.parse("tr.athing:has(+ tr .score)")
        guard case .has(let relativeGroup) = group.selectors[0].steps[0].compound.components[2] else {
            return XCTFail("expected :has selector")
        }
        XCTAssertEqual(.adjacentSibling, relativeGroup.selectors[0].steps.first?.combinator)
    }

    func testParsesNthChildExpressions() throws {
        _ = try CSSSelectorParser.parse("li:nth-child(odd)")
        _ = try CSSSelectorParser.parse("article:nth-of-type(2n+1)")
        _ = try CSSSelectorParser.parse("article:nth-child(3)")
    }

    func testParsesContainsArgumentWithParenthesesAndEscapedDelimiter() throws {
        _ = try CSSSelectorParser.parse("p:contains(this (is good))")
        _ = try CSSSelectorParser.parse("p:contains(this is bad\\))")
    }

    func testRejectsUnsupportedPseudoSelectorSyntax() {
        XCTAssertThrowsError(try CSSSelectorParser.parse("a:matches(img)"))
    }

    func testRejectsInvalidNthExpression() {
        XCTAssertThrowsError(try CSSSelectorParser.parse("li:nth-child(sideways)"))
    }
}
