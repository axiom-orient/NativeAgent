
actor ASKPretextPreparedTextStore {
    private static let defaultCapacity = 512

    struct PreparedText: Sendable {
        let key: ASKPreparedTextKey
    }

    private let capacity: Int
    private var nextID: Int = 0
    private var storage: [ASKPreparedTextStorageID: PreparedText] = [:]
    private var storageIDByKey: [ASKPreparedTextKey: ASKPreparedTextStorageID] = [:]
    private var recency: [ASKPreparedTextStorageID] = []

    init(capacity: Int = defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    func insert(_ key: ASKPreparedTextKey) -> ASKPreparedTextHandle {
        if let existingID = storageIDByKey[key] {
            touch(existingID)
            return ASKPreparedTextHandle(storageID: existingID)
        }
        nextID += 1
        let storageID = ASKPreparedTextStorageID("prepared-\(nextID)")
        storage[storageID] = PreparedText(key: key)
        storageIDByKey[key] = storageID
        recency.append(storageID)
        evictIfNeeded()
        return ASKPreparedTextHandle(storageID: storageID)
    }

    func preparedText(for handle: ASKPreparedTextHandle) throws -> PreparedText {
        guard let preparedText = storage[handle.storageID] else {
            throw ASKPretextTypographyError.unknownHandle(handle)
        }
        touch(handle.storageID)
        return preparedText
    }

    private func touch(_ storageID: ASKPreparedTextStorageID) {
        recency.removeAll { $0 == storageID }
        recency.append(storageID)
    }

    private func evictIfNeeded() {
        while storage.count > capacity, let evictedID = recency.first {
            recency.removeFirst()
            if let evicted = storage.removeValue(forKey: evictedID) {
                storageIDByKey.removeValue(forKey: evicted.key)
            }
        }
    }
}
