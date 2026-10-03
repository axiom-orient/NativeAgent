package extension ASKPageSourceAnchor {
    func matches(
        sourceID querySourceID: ASKPageSourceID,
        overlapping queryRange: ASKPageSourceRange? = nil
    ) -> Bool {
        guard sourceID == querySourceID else {
            return false
        }
        guard let queryRange else {
            return true
        }
        guard let range else {
            return false
        }
        return range.intersection(queryRange) != nil
    }
}
