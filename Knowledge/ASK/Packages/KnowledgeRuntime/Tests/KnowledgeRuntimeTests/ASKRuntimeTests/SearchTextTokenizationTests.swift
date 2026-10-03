import Foundation
import Testing
@testable import KnowledgeRuntime

/// Query tokens gate both FTS candidate selection and lexical ranking, so a script the
/// tokenizer does not recognise is not merely ranked lower — it returns nothing at all.
struct SearchTextTokenizationTests {
    @Test
    func decomposedAndComposedHangulProduceTheSameTokens() {
        let composed = "증거 색인"
        let decomposed = composed.decomposedStringWithCanonicalMapping

        #expect(SearchText.tokenize(composed) == ["증거", "색인"])
        #expect(SearchText.tokenize(decomposed) == SearchText.tokenize(composed))
    }

    @Test(arguments: [
        ("Han", "文書 索引", ["文書", "索引"]),
        ("kana", "かな カナ", ["かな", "カナ"]),
        ("Cyrillic", "поиск индекс", ["поиск", "индекс"]),
        ("ASCII", "anchor resolver", ["anchor", "resolver"]),
    ])
    func scriptsAreTokenizedAsWholeWords(_ name: String, _ text: String, _ expected: [String]) {
        #expect(SearchText.tokenize(text) == expected, "\(name) tokenization")
    }

    /// An accented word used to be split at the accent, producing fragments that match
    /// nothing.
    @Test
    func accentedLatinIsNotFragmented() {
        #expect(SearchText.tokenize("café naïve") == ["café", "naïve"])
    }

    /// Korean and CJK carry meaning in one character, so the two-character minimum
    /// silently made single-syllable queries unanswerable.
    @Test
    func singleCharacterCJKQueriesProduceAToken() {
        #expect(SearchText.tokenize("책") == ["책"])
        #expect(SearchText.tokenize("文") == ["文"])
    }

    /// The minimum still applies to space-separated scripts, where a stray letter is noise.
    @Test
    func singleCharacterLatinIsStillDropped() {
        #expect(SearchText.tokenize("a b").isEmpty)
        #expect(SearchText.tokenize("a resolver") == ["resolver"])
    }

    @Test
    func punctuationAndWhitespaceRemainSeparators() {
        #expect(SearchText.tokenize("journal, recovery; replay") == ["journal", "recovery", "replay"])
        #expect(SearchText.tokenize("  ").isEmpty)
    }

    /// Tokens are embedded in an FTS5 MATCH expression, so none may carry a quote.
    @Test
    func tokensNeverContainFTSMetacharacters() {
        let tokens = SearchText.tokenize(#"drop" OR "1"="1 -- x"#)
        #expect(tokens.allSatisfy { !$0.contains("\"") && !$0.contains("*") && !$0.contains(":") })
    }
}
