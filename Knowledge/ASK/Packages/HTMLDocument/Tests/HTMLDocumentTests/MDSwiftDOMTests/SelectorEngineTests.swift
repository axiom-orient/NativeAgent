import XCTest
@testable import HTMLDocument

final class SelectorEngineTests: XCTestCase {
    func testSelectsByTagClassIdAndAttribute() throws {
        let document = try Soup.parseHTML("""
        <div id='wrap'>
          <p id='p1' class='lead'>One</p>
          <p id='p2' class='body'>Two</p>
          <a id='a1' class='lead' href='https://example.com'>Link</a>
        </div>
        """)

        XCTAssertEqual(["p1"], try document.select("p.lead").map(\.id))
        XCTAssertEqual(["a1"], try document.select("a[href]").map(\.id))
        XCTAssertEqual(["p1", "p2"], try document.select("#wrap > p").map(\.id))
    }

    func testGroupedSelectorsDeduplicateMatches() throws {
        let document = try Soup.parseHTML("<div><p id='p1' class='lead'>One</p></div>")
        let ids = try document.select("p, p.lead").map(\.id)
        XCTAssertEqual(["p1"], ids)
    }

    func testElementSelectionCanMatchRoot() throws {
        let document = try Soup.parseHTML("<p id='p1' class='lead'>One</p>")
        let root = try XCTUnwrap(document.documentElement)
        XCTAssertEqual(["p1"], try root.select("p.lead").map(\.id))
    }

    func testMatchesHackerNewsStyleAdjacentMetadataRows() throws {
        let document = try Soup.parseHTML("""
        <table>
          <tr class='athing submission' id='story-1'>
            <td><a class='titlelink' href='https://example.com/story'>LittleSnitch for Linux</a></td>
          </tr>
          <tr>
            <td class='subtext'>
              <span class='score' id='score_story-1'>391 points</span>
            </td>
          </tr>
        </table>
        """)

        XCTAssertEqual(["score_story-1"], try document.select("tr.athing + tr .score").map(\.id))
        XCTAssertEqual(["score_story-1"], try document.select("table tr.athing + tr > td.subtext > span.score").map(\.id))
        XCTAssertEqual(["story-1"], try document.select("tr.athing:has(+ tr .score)").map(\.id))
    }

    func testMatchesRelativeGeneralSiblingSelectorsInsideHas() throws {
        let document = try Soup.parseHTML("""
        <div>
          <section id='first' class='card'></section>
          <hr>
          <section id='second' class='card'>
            <a id='target' href='https://example.com'>Link</a>
          </section>
        </div>
        """)

        XCTAssertEqual(["first"], try document.select("section.card:has(~ section.card a)").map(\.id))
    }

    func testMatchesContainsOwnAgainstDirectTextOnly() throws {
        let document = try Soup.parseHTML("""
        <div>
          <h2 id='direct'>Community highlights <span>beta</span></h2>
          <h2 id='nested'><span>Community highlights</span></h2>
        </div>
        """)

        XCTAssertEqual(["direct"], try document.select("h2:containsOwn(Community highlights)").map(\.id))
    }

    func testMatchesStructuralSelectorsWithInterstitialBlocks() throws {
        let document = try Soup.parseHTML("""
        <section id='feed'>
          <article id='first' class='card'></article>
          <aside id='ad'></aside>
          <article id='second' class='card'></article>
          <article id='third' class='card'></article>
        </section>
        """)

        XCTAssertEqual(["first"], try document.select("#feed > article:first-of-type").map(\.id))
        XCTAssertEqual(["third"], try document.select("#feed > article:last-of-type").map(\.id))
        XCTAssertEqual(["second"], try document.select("#feed > article:nth-of-type(2)").map(\.id))
        XCTAssertEqual(["second"], try document.select("#feed > article:nth-child(3)").map(\.id))
    }

    func testMatchesProductHuntStyleDataTestSelectors() throws {
        let document = try Soup.parseHTML("""
        <main>
          <article id='item' data-test='post-item-123'>
            <a id='name' data-test='post-name-123' href='/products/velo'>Velo</a>
            <p id='tagline' data-test='product-header-tagline'>Share anything as video messages</p>
          </article>
        </main>
        """)

        XCTAssertEqual(["item"], try document.select("[data-test^=post-item-]").map(\.id))
        XCTAssertEqual(["name"], try document.select("a[data-test*=post-name-]").map(\.id))
        XCTAssertEqual(["tagline"], try document.select("[data-test$=tagline]").map(\.id))
    }
}
