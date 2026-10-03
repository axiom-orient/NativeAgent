import Testing
@testable import HTMLDocument

struct SelectorCacheTests {
    @Test
    func cachesAndEvictsSelectors() async throws {
        let cache = SelectorCache(capacity: 2)

        _ = try await cache.selector(for: "p")
        _ = try await cache.selector(for: "a")
        let countAfterTwo = await cache.count()
        #expect(countAfterTwo == 2)

        _ = try await cache.selector(for: "div")
        let countAfterThree = await cache.count()
        #expect(countAfterThree == 2)

        _ = try await cache.selector(for: "div")
        let countAfterHit = await cache.count()
        #expect(countAfterHit == 2)
    }
}
