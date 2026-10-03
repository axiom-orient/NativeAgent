
    public actor SelectorCache {
        private var storage: [String: CSSSelectorGroup] = [:]
        private var order: [String] = []
        public let capacity: Int

        public init(capacity: Int = 128) {
            self.capacity = max(1, capacity)
        }

        public func selector(for query: String) throws -> CSSSelectorGroup {
            if let cached = storage[query] {
                touch(query)
                return cached
            }

            let parsed = try CSSSelectorParser.parse(query)
            storage[query] = parsed
            order.removeAll(where: { $0 == query })
            order.append(query)
            evictIfNeeded()
            return parsed
        }

        public func clear() {
            storage.removeAll(keepingCapacity: false)
            order.removeAll(keepingCapacity: false)
        }

        public func count() -> Int {
            storage.count
        }

        private func touch(_ query: String) {
            order.removeAll(where: { $0 == query })
            order.append(query)
        }

        private func evictIfNeeded() {
            while order.count > capacity {
                let oldest = order.removeFirst()
                storage.removeValue(forKey: oldest)
            }
        }
    }
