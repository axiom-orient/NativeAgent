
public struct ASKRenderedCanvasSourceNavigator: Sendable {
    public init() {}

    public func fragments(
        in page: ASKRenderedCanvasPage,
        sourceID: ASKPageSourceID,
        overlapping range: ASKPageSourceRange? = nil
    ) -> [ASKRenderedCanvasFragmentMatch] {
        page.textFragments.enumerated().compactMap { index, fragment in
            guard let anchor = fragment.sourceAnchor,
                  anchor.matches(sourceID: sourceID, overlapping: range)
            else {
                return nil
            }
            return ASKRenderedCanvasFragmentMatch(fragmentIndex: index, fragment: fragment)
        }
    }

    public func notes(
        in page: ASKRenderedCanvasPage,
        sourceID: ASKPageSourceID,
        overlapping range: ASKPageSourceRange? = nil
    ) -> [ASKRenderedCanvasNoteMatch] {
        page.notes.enumerated().compactMap { index, note in
            guard let anchor = note.sourceAnchor,
                  anchor.matches(sourceID: sourceID, overlapping: range)
            else {
                return nil
            }
            return ASKRenderedCanvasNoteMatch(noteIndex: index, note: note)
        }
    }
}

public struct ASKRenderedCanvasFragmentMatch: Sendable, Hashable, Codable {
    public let fragmentIndex: Int
    public let fragment: ASKRenderedCanvasTextFragment

    public init(fragmentIndex: Int, fragment: ASKRenderedCanvasTextFragment) {
        self.fragmentIndex = fragmentIndex
        self.fragment = fragment
    }
}

public struct ASKRenderedCanvasNoteMatch: Sendable, Hashable, Codable {
    public let noteIndex: Int
    public let note: ASKRenderedCanvasNote

    public init(noteIndex: Int, note: ASKRenderedCanvasNote) {
        self.noteIndex = noteIndex
        self.note = note
    }
}
