package enum SearchText {
    package static func tokenize(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentLength = 0

        func flush() {
            defer {
                current.removeAll(keepingCapacity: true)
                currentLength = 0
            }
            guard currentLength >= 2 || isStandaloneToken(current) else { return }
            tokens.append(current.lowercased())
        }

        // Canonical composition first: on Apple filesystems Hangul commonly arrives
        // decomposed, and comparing decomposed jamo against composed syllables silently
        // produces no tokens at all.
        for character in value.precomposedStringWithCanonicalMapping {
            if isTokenCharacter(character) {
                current.append(character)
                currentLength += 1
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    package static func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty, !haystack.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    /// Word characters are defined by Unicode category rather than by an explicit range
    /// list. The previous allow-list covered ASCII and precomposed Hangul only, so Han,
    /// kana, Cyrillic and accented Latin were treated as separators — an accented word was
    /// split into fragments and a CJK word disappeared entirely.
    private static func isTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
    }

    /// Scripts that do not separate words with spaces carry meaning in a single character,
    /// so the two-character minimum would make a one-syllable query unanswerable.
    private static func isStandaloneToken(_ token: String) -> Bool {
        guard token.count == 1, let scalar = token.unicodeScalars.first else { return false }
        let value = scalar.value
        return (0xAC00 ... 0xD7A3).contains(value)       // Hangul syllables
            || (0x1100 ... 0x11FF).contains(value)       // Hangul jamo
            || (0x3130 ... 0x318F).contains(value)       // Hangul compatibility jamo
            || (0x3040 ... 0x30FF).contains(value)       // Hiragana and katakana
            || (0x3400 ... 0x4DBF).contains(value)       // CJK unified ideographs extension A
            || (0x4E00 ... 0x9FFF).contains(value)       // CJK unified ideographs
            || (0xF900 ... 0xFAFF).contains(value)       // CJK compatibility ideographs
    }
}
