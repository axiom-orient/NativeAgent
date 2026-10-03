import Foundation

public struct JSONValueStructureLimits: Sendable, Equatable {
    public let maximumDepth: Int
    public let maximumNodes: Int
    public let maximumCollectionEntries: Int
    public let maximumStringUTF8Bytes: Int
    public let maximumKeyUTF8Bytes: Int
    public let maximumTotalStringUTF8Bytes: Int

    public init(
        maximumDepth: Int,
        maximumNodes: Int,
        maximumCollectionEntries: Int,
        maximumStringUTF8Bytes: Int,
        maximumKeyUTF8Bytes: Int,
        maximumTotalStringUTF8Bytes: Int
    ) {
        self.maximumDepth = maximumDepth
        self.maximumNodes = maximumNodes
        self.maximumCollectionEntries = maximumCollectionEntries
        self.maximumStringUTF8Bytes = maximumStringUTF8Bytes
        self.maximumKeyUTF8Bytes = maximumKeyUTF8Bytes
        self.maximumTotalStringUTF8Bytes = maximumTotalStringUTF8Bytes
    }
}

public enum JSONValueStructureError: Error, Equatable, LocalizedError {
    case depth(limit: Int)
    case nodes(limit: Int)
    case collectionEntries(limit: Int)
    case stringBytes(limit: Int)
    case keyBytes(limit: Int)
    case totalStringBytes(limit: Int)
    case nonFiniteNumber

    public var errorDescription: String? {
        switch self {
        case .depth(let limit):
            return "JSON depth exceeds \(limit)."
        case .nodes(let limit):
            return "JSON node count exceeds \(limit)."
        case .collectionEntries(let limit):
            return "JSON collection entry count exceeds \(limit)."
        case .stringBytes(let limit):
            return "JSON string exceeds \(limit) UTF-8 bytes."
        case .keyBytes(let limit):
            return "JSON object key exceeds \(limit) UTF-8 bytes."
        case .totalStringBytes(let limit):
            return "JSON total string content exceeds \(limit) UTF-8 bytes."
        case .nonFiniteNumber:
            return "JSON numbers must be finite."
        }
    }
}

extension JSONValue {
    /// Iteratively validates untrusted JSON before recursive encoding or decoding work.
    public func validateStructure(limits: JSONValueStructureLimits) throws {
        var stack: [(value: JSONValue, depth: Int)] = [(self, 1)]
        var visitedNodes = 0
        var totalStringBytes = 0

        while let next = stack.popLast() {
            guard next.depth <= limits.maximumDepth else {
                throw JSONValueStructureError.depth(limit: limits.maximumDepth)
            }
            guard visitedNodes < limits.maximumNodes else {
                throw JSONValueStructureError.nodes(limit: limits.maximumNodes)
            }
            visitedNodes += 1

            switch next.value {
            case .null, .bool, .integer:
                break

            case .number(let value):
                guard value.isFinite else {
                    throw JSONValueStructureError.nonFiniteNumber
                }

            case .string(let value):
                let byteCount = value.utf8.count
                guard byteCount <= limits.maximumStringUTF8Bytes else {
                    throw JSONValueStructureError.stringBytes(
                        limit: limits.maximumStringUTF8Bytes
                    )
                }
                totalStringBytes = try addingStringBytes(
                    byteCount,
                    to: totalStringBytes,
                    limit: limits.maximumTotalStringUTF8Bytes
                )

            case .array(let values):
                try validateCollectionCount(values.count, limits: limits)
                try reserveNodes(
                    values.count,
                    visitedNodes: visitedNodes,
                    scheduledNodes: stack.count,
                    limit: limits.maximumNodes
                )
                if values.isEmpty == false, next.depth == limits.maximumDepth {
                    throw JSONValueStructureError.depth(limit: limits.maximumDepth)
                }
                for value in values.reversed() {
                    stack.append((value, next.depth + 1))
                }

            case .object(let values):
                try validateCollectionCount(values.count, limits: limits)
                try reserveNodes(
                    values.count,
                    visitedNodes: visitedNodes,
                    scheduledNodes: stack.count,
                    limit: limits.maximumNodes
                )
                if values.isEmpty == false, next.depth == limits.maximumDepth {
                    throw JSONValueStructureError.depth(limit: limits.maximumDepth)
                }

                let keys = values.keys.sorted()
                for key in keys {
                    let keyBytes = key.utf8.count
                    guard keyBytes <= limits.maximumKeyUTF8Bytes else {
                        throw JSONValueStructureError.keyBytes(
                            limit: limits.maximumKeyUTF8Bytes
                        )
                    }
                    totalStringBytes = try addingStringBytes(
                        keyBytes,
                        to: totalStringBytes,
                        limit: limits.maximumTotalStringUTF8Bytes
                    )
                }
                for key in keys.reversed() {
                    if let value = values[key] {
                        stack.append((value, next.depth + 1))
                    }
                }
            }
        }
    }

    private func validateCollectionCount(
        _ count: Int,
        limits: JSONValueStructureLimits
    ) throws {
        guard count <= limits.maximumCollectionEntries else {
            throw JSONValueStructureError.collectionEntries(
                limit: limits.maximumCollectionEntries
            )
        }
    }

    private func reserveNodes(
        _ count: Int,
        visitedNodes: Int,
        scheduledNodes: Int,
        limit: Int
    ) throws {
        guard visitedNodes <= limit,
              scheduledNodes <= limit - visitedNodes,
              count <= limit - visitedNodes - scheduledNodes else {
            throw JSONValueStructureError.nodes(limit: limit)
        }
    }

    private func addingStringBytes(
        _ addition: Int,
        to current: Int,
        limit: Int
    ) throws -> Int {
        guard addition <= limit, current <= limit - addition else {
            throw JSONValueStructureError.totalStringBytes(limit: limit)
        }
        return current + addition
    }
}
