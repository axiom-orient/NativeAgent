import Foundation
import Testing
@testable import SourceCapture

struct OperationalHTMLFixtureParityTests {
    private struct FixtureExpectedFragment: Codable, Equatable {
        let heading: String
        let text: String
    }

    private struct FixtureExpectedExtraction: Codable, Equatable {
        let title: String
        let canonicalURL: String
        let language: String?
        let description: String?
        let publishedAt: String?
        let siteName: String?
        let markdown: String
        let fragments: [FixtureExpectedFragment]

        private enum CodingKeys: String, CodingKey {
            case title
            case canonicalURL = "canonical_url"
            case language
            case description
            case publishedAt = "published_at"
            case siteName = "site_name"
            case markdown
            case fragments
        }
    }

    private struct FixtureRecord: Codable {
        let pageURL: String
        let expected: FixtureExpectedExtraction

        private enum CodingKeys: String, CodingKey {
            case pageURL = "page_url"
            case expected
        }
    }

    @Test
    func blockquoteAndPreFixtureMatchesExtractionSnapshot() throws {
        try assertFixtureMatches(name: "blockquote_and_pre")
    }

    @Test
    func bodyFallbackEntitiesFixtureMatchesExtractionSnapshot() throws {
        try assertFixtureMatches(name: "body_fallback_entities")
    }

    @Test
    func mainFallbackWithTimeFixtureMatchesExtractionSnapshot() throws {
        try assertFixtureMatches(name: "main_fallback_with_time")
    }

    @Test
    func malformedRecoveryFixtureMatchesExtractionSnapshot() throws {
        try assertFixtureMatches(name: "malformed_recovery")
    }

    @Test
    func newsArticleStructuredFixtureMatchesExtractionSnapshot() throws {
        try assertFixtureMatches(name: "news_article_structured")
    }

    @Test
    func noiseFilterFixtureMatchesExtractionSnapshot() throws {
        try assertFixtureMatches(name: "noise_filter")
    }

    private func assertFixtureMatches(name: String, filePath: StaticString = #filePath) throws {
        let fixture = try loadFixture(name: name, filePath: filePath)
        let result = try WebExtractor.extractPage(html: fixture.html, url: fixture.record.pageURL)
        let expected = fixture.record.expected
        let actualFragments = result.fragments.map { FixtureExpectedFragment(heading: $0.heading, text: $0.text) }

        #expect(result.title == expected.title)
        #expect((result.canonicalURL ?? fixture.record.pageURL) == expected.canonicalURL)
        #expect(result.language == expected.language)
        #expect(result.description == expected.description)
        #expect(result.publishedAt == expected.publishedAt)
        #expect(result.siteName == expected.siteName)
        #expect(result.markdown == expected.markdown)
        #expect(actualFragments == expected.fragments)
    }

    private func loadFixture(name: String, filePath: StaticString = #filePath) throws -> (html: String, record: FixtureRecord) {
        let decoder = JSONDecoder()
        let directory = SimulatorTestSupport
            .testFileDirectory(filePath: filePath)
            .appendingPathComponent("Resources/operational_fixtures", isDirectory: true)
        let jsonURL = directory.appendingPathComponent(name).appendingPathExtension("json")
        let htmlURL = directory.appendingPathComponent(name).appendingPathExtension("html")
        let record = try decoder.decode(FixtureRecord.self, from: Data(contentsOf: jsonURL))
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        return (html, record)
    }
}
