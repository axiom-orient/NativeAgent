import XCTest
@testable import HTMLDocument

final class RealWorldExtractionTests: XCTestCase {
    private struct ProductCard: Equatable {
        let title: String
        let tagline: String
        let href: String
    }

    private struct HackerNewsStory: Equatable {
        let title: String
        let href: String
        let points: String
    }

    private struct CommunityEntry: Equatable {
        let title: String
        let href: String
        let marker: String
    }

    private struct AlternativeCard: Equatable {
        let title: String
        let summary: String
        let href: String
    }

    func testExtractsOrganicProductHuntStyleCardsFromSectionScopedFeed() throws {
        let document = try Soup.parseHTML("""
        <main>
          <section id='today'>
            <h2>Top Products Launching Today <span>live</span></h2>
            <article class='product promoted' data-test=post-item-123>
              <a data-test=post-name-123 href=/products/velo>Velo</a>
              <span class='badge'>Promoted</span>
              <p data-test=product-header-tagline>Share anything as video messages</p>
            </article>
            <div class='newsletter'>Get the best of Product Hunt, directly in your inbox.</div>
            <article class='product' data-test=post-item-124>
              <a data-test=post-name-124 href=/products/browser-arena>Browser Arena</a>
              <p data-test=product-header-tagline>Open-source benchmarks for cloud browser infrastructure</p>
            </article>
          </section>
        </main>
        """)

        let cards = try document
            .select("section:has(> h2:containsOwn(Top Products Launching Today)) > article.product:has(> a[data-test*=post-name-]):not(:has(> .badge:containsOwn(Promoted)))")
            .map { article in
                let link = try XCTUnwrap(article.select("a[data-test*=post-name-]").first)
                let tagline = try XCTUnwrap(article.select("[data-test$=tagline]").first)
                return ProductCard(
                    title: link.normalizedText,
                    tagline: tagline.normalizedText,
                    href: try XCTUnwrap(link.attribute(named: "href"))
                )
            }

        XCTAssertEqual([
            ProductCard(
                title: "Browser Arena",
                tagline: "Open-source benchmarks for cloud browser infrastructure",
                href: "/products/browser-arena"
            )
        ], cards)
    }

    func testExtractsHackerNewsStyleStoriesWithRelativeHasMetadataGuard() throws {
        let document = try Soup.parseHTML("""
        <table>
          <tr class=athing id=story-1>
            <td class=titleline><a href=https://example.com/story-1>LittleSnitch for Linux</a></td>
          </tr>
          <tr>
            <td class=subtext><span class=score id=score_story-1>391 points</span></td>
          </tr>
          <tr class=athing id=story-2>
            <td class=titleline><a href=https://example.com/story-2>USB for Software Developers</a></td>
          </tr>
          <tr>
            <td class=subtext><span class=score id=score_story-2>259 points</span></td>
          </tr>
        </table>
        """)

        let storyRows = try document.select("tr.athing:has(+ tr .score)")
        let metadataRows = try document.select("tr.athing:has(+ tr .score) + tr")
        XCTAssertEqual(storyRows.count, metadataRows.count)

        let stories = try zip(storyRows, metadataRows).map { storyRow, metadataRow in
            let link = try XCTUnwrap(storyRow.select("a").first)
            let score = try XCTUnwrap(metadataRow.select(".score").first)
            return HackerNewsStory(
                title: link.normalizedText,
                href: try XCTUnwrap(link.attribute(named: "href")),
                points: score.normalizedText
            )
        }

        XCTAssertEqual([
            HackerNewsStory(title: "LittleSnitch for Linux", href: "https://example.com/story-1", points: "391 points"),
            HackerNewsStory(title: "USB for Software Developers", href: "https://example.com/story-2", points: "259 points")
        ], stories)
    }

    func testExtractsRedditStyleCommunityEntriesFromOwnTextSectionMarker() throws {
        let document = try Soup.parseHTML("""
        <main>
          <section id='community-highlights'>
            <h2>Community highlights <span>beta</span></h2>
            <article>
              <a href='/r/startups/comments/xyz/example/'>If your goal is to get rich, DON’T found a tech startup</a>
            </article>
            <article>
              <a href='/r/startups/comments/abc/another/'>The truth about startup pivots</a>
            </article>
          </section>
          <section id='lookalike'>
            <h2><span>Community highlights</span></h2>
            <article><a href='/r/startups/comments/nope/hidden/'>Hidden</a></article>
          </section>
        </main>
        """)

        let entries = try document
            .select("section:has(> h2:containsOwn(Community highlights)) > article:has(> a[href*='/r/startups/comments/'])")
            .map { article in
                let link = try XCTUnwrap(article.select("a[href*='/r/startups/comments/']").first)
                return CommunityEntry(
                    title: link.normalizedText,
                    href: try XCTUnwrap(link.attribute(named: "href")),
                    marker: "Community highlights"
                )
            }

        XCTAssertEqual([
            CommunityEntry(title: "If your goal is to get rich, DON’T found a tech startup", href: "/r/startups/comments/xyz/example/", marker: "Community highlights"),
            CommunityEntry(title: "The truth about startup pivots", href: "/r/startups/comments/abc/another/", marker: "Community highlights")
        ], entries)
    }

    func testExtractsAlternativeToStyleCardsDespiteInterstitialAdSlots() throws {
        let document = try Soup.parseHTML("""
        <section id='new-apps'>
          <article id='apfel' class='app-card'>
            <h2><a href=/software/apfel/>apfel</a></h2>
            <p class='summary'>Local AI assistant for macOS.</p>
            <section class='license'><h3>Cost / License</h3><ul><li>Free</li></ul></section>
            <section class='platforms'><h3>Platforms</h3><ul><li>Mac</li></ul></section>
          </article>
          <aside class='ad'>Ad ONLYOFFICE</aside>
          <article id='clearly-markdown' class='app-card'>
            <h2><a href=/software/clearly-markdown/>Clearly Markdown</a></h2>
            <p class='summary'>Clean, native Markdown editor for Mac with syntax highlighting and open source.</p>
            <section class='license'><h3>Cost / License</h3><ul><li>Free</li><li>Open Source</li></ul></section>
            <section class='platforms'><h3>Platforms</h3><ul><li>Mac</li></ul></section>
          </article>
        </section>
        """)

        let cards = try document
            .select("#new-apps > article.app-card:nth-of-type(2):has(> .license h3:containsOwn(Cost / License)):has(> .platforms):contains(Open Source)")
            .map { article in
                let heading = try XCTUnwrap(article.select("h2 a").first)
                return AlternativeCard(
                    title: heading.normalizedText,
                    summary: article.normalizedText,
                    href: try XCTUnwrap(heading.attribute(named: "href"))
                )
            }

        XCTAssertEqual([
            AlternativeCard(
                title: "Clearly Markdown",
                summary: "Clearly Markdown Clean, native Markdown editor for Mac with syntax highlighting and open source. Cost / License Free Open Source Platforms Mac",
                href: "/software/clearly-markdown/"
            )
        ], cards)
    }
}
