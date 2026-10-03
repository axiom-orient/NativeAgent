import XCTest
@testable import WorkWiki

final class ASKWorkWikiSearchTests: XCTestCase, @unchecked Sendable {
    private func document(
        path: String = "wiki/docs/search.md",
        title: String = "Search Notes",
        body: String
    ) -> ASKWorkWikiIndexedDocument {
        ASKWorkWikiIndexedDocument(
            relativePath: path,
            category: .docs,
            title: title,
            body: body
        )
    }

    func testSnippetUsesBodyLineForSecondQueryToken() throws {
        let hits = try ASKWorkWikiSearch.search(
            query: "alpha beta",
            documents: [document(title: "Alpha overview", body: "Evidence for beta is here.")],
            limit: 1
        )

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].snippet, "Evidence for beta is here.")
    }

    func testSnippetPrefersLineContainingAllTokens() throws {
        let hits = try ASKWorkWikiSearch.search(
            query: "alpha beta",
            documents: [document(body: "Alpha appears alone.\nAlpha and beta appear together.")],
            limit: 1
        )

        XCTAssertEqual(hits[0].snippet, "Alpha and beta appear together.")
    }

    func testSnippetFallsBackToTitleWhenOnlyTitleMatches() throws {
        let hits = try ASKWorkWikiSearch.search(
            query: "alpha beta",
            documents: [document(title: "Alpha beta overview", body: "No matching evidence here.")],
            limit: 1
        )

        XCTAssertEqual(hits[0].snippet, "Alpha beta overview")
    }

    func testSnippetChangePreservesScoreOrderingAndLimit() throws {
        let hits = try ASKWorkWikiSearch.search(
            query: "alpha beta",
            documents: [
                document(path: "wiki/docs/a.md", title: "Alpha", body: "Beta evidence."),
                document(path: "wiki/docs/b.md", title: "Beta", body: "Alpha evidence."),
                document(path: "wiki/docs/c.md", title: "Unrelated", body: "Alpha evidence only.")
            ],
            limit: 2
        )

        XCTAssertEqual(hits.map(\.relativePath), ["wiki/docs/a.md", "wiki/docs/b.md"])
        XCTAssertEqual(hits.map(\.score), [7, 7])
        XCTAssertEqual(hits.count, 2)
    }
}
