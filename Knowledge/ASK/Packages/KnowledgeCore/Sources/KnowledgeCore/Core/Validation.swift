import Foundation

public protocol ASKValidatable {
    func validate() throws
}

public enum ASKValidation {
    public static func requireNonEmpty(_ field: String, _ value: String) throws {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ASKError.validation("field `\(field)` must not be empty")
        }
    }

    public static func requirePathSafeID(_ field: String, _ value: String) throws {
        try requireNonEmpty(field, value)
        let valid = value.unicodeScalars.allSatisfy { scalar in
            let character = Character(scalar)
            return scalar.isASCII && (character.isLowercase || character.isNumber || character == "-" || character == "_")
        }
        if !valid {
            throw ASKError.validation("field `\(field)` must contain only [a-z0-9_-]")
        }
    }

    public static func requireRelativePath(_ field: String, _ value: String) throws {
        try requireNonEmpty(field, value)
        if value.hasPrefix("/") || value.split(separator: "/").contains("..") {
            throw ASKError.validation("field `\(field)` must be a safe relative path")
        }
    }
}

package func requireNonEmpty(_ field: String, _ value: String) throws {
    try ASKValidation.requireNonEmpty(field, value)
}

package func requireSlug(_ field: String, _ value: String) throws {
    try requireNonEmpty(field, value)
    let valid = value.unicodeScalars.allSatisfy { scalar in
        let ch = Character(scalar)
        return scalar.isASCII && (ch.isLowercase || ch.isNumber || ch == "-" || ch == "/")
    }
    if !valid {
        throw ASKError.validation("field `\(field)` must contain only [a-z0-9-/]")
    }
}

package func requirePathSafeID(_ field: String, _ value: String) throws {
    try ASKValidation.requirePathSafeID(field, value)
}

package func requireRelpath(_ field: String, _ value: String) throws {
    try ASKValidation.requireRelativePath(field, value)
}

package func requireTimestamp(_ field: String, _ value: String) throws {
    try requireNonEmpty(field, value)
    guard value.count >= 20 else {
        throw ASKError.validation("field `\(field)` must look like RFC3339")
    }
    guard ASKTimestamp.isValidRFC3339(value) else {
        throw ASKError.validation("field `\(field)` must be valid RFC3339")
    }
}

package func requireUniqueNonEmpty(_ field: String, _ values: [String]) throws {
    var seen = Set<String>()
    for value in values {
        try requireNonEmpty(field, value)
        if !seen.insert(value).inserted {
            throw ASKError.validation("field `\(field)` must not contain duplicates: \(value)")
        }
    }
}

package func isBlank(_ value: String?) -> Bool {
    value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
}

package func requireChoiceID(_ field: String, _ value: String) throws {
    _ = try PatchChoiceID(validating: value, field: field)
}

package func requireSortedUniqueOrdinals(_ values: [Int]) throws {
    var seen = Set<Int>()
    var previous = -1
    for value in values {
        if value < 0 {
            throw ASKError.validation("fragment ordinal must be >= 0")
        }
        if !seen.insert(value).inserted {
            throw ASKError.validation("fragment ordinals must be unique")
        }
        if previous > value {
            throw ASKError.validation("fragment ordinals must be sorted ascending")
        }
        previous = value
    }
}

package func requireVersion(_ version: String, expected: String) throws {
    guard version == expected else {
        throw ASKError.validation("unsupported version `\(version)`; expected `\(expected)`")
    }
}
