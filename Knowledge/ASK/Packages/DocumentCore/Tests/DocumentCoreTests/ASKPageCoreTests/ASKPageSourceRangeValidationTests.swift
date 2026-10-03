import DocumentCore
import Foundation
import Testing

@Test("Validated source ranges reject negative starts")
func validatedSourceRangeRejectsNegativeStart() {
    #expect(throws: ASKPageSourceRange.ValidationError.self) {
        try ASKPageSourceRange(validatingStart: -1, end: 0)
    }
}

@Test("Validated source ranges reject reversed bounds")
func validatedSourceRangeRejectsReversedBounds() {
    #expect(throws: ASKPageSourceRange.ValidationError.self) {
        try ASKPageSourceRange(validatingStart: 4, end: 3)
    }
}

@Test("Source range decoding preserves the invariant")
func sourceRangeDecodingPreservesInvariant() throws {
    let decoder = JSONDecoder()
    let valid = try decoder.decode(
        ASKPageSourceRange.self,
        from: Data(#"{"start":2,"end":5}"#.utf8)
    )
    #expect(valid == ASKPageSourceRange(start: 2, end: 5))

    #expect(throws: DecodingError.self) {
        try decoder.decode(
            ASKPageSourceRange.self,
            from: Data(#"{"start":-1,"end":5}"#.utf8)
        )
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(
            ASKPageSourceRange.self,
            from: Data(#"{"start":5,"end":2}"#.utf8)
        )
    }
}

@Test("Source range offset rejects integer overflow")
func sourceRangeOffsetRejectsOverflow() {
    let range = ASKPageSourceRange(start: Int.max - 2, end: Int.max)
    #expect(range.offset(by: 1) == nil)
    #expect(range.offset(by: Int.min) == nil)
}
