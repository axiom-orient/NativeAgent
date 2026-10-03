import Foundation

public func sourceURI(_ sourceID: String) -> String { "ask://source/\(sourceID)" }
public func fragmentURI(_ fragmentID: String) -> String { "ask://fragment/\(fragmentID)" }
public func authorityURI(_ recordID: String) -> String { "ask://authority/\(recordID)" }
public func projectionURI(_ slug: String) -> String { "ask://projection/\(slug)" }

/// Content-addressed identity, deliberately not a cryptographic digest.
///
/// Every ID this produces is written into the journal, so the algorithm is part
/// of the on-disk contract: changing it gives a re-planned identical request a
/// new patch ID, which breaks dedup against patches already recorded. It is used
/// for identity and change detection only — the places that need tamper evidence
/// (raw evidence `content_hash`, the storage generation marker) use SHA-256.
public func stableHash(_ parts: some Collection<String>) -> String {
    let joined = parts.joined(separator: "\u{001F}")
    let value = fnv1a64(joined.utf8)
    return String(format: "%016llx", value)
}

public func stableID(prefix: String, parts: some Collection<String>) -> String {
    "\(prefix)_\(stableHash(parts))"
}

public func canonicalMapString(_ values: ASKFields) -> String {
    values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "\u{001E}")
}

public func stableHashMap(_ values: ASKFields) -> String {
    stableHash([canonicalMapString(values)])
}

package func fnv1a64<S: Sequence<UInt8>>(_ bytes: S) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in bytes {
        hash ^= UInt64(byte)
        hash = hash &* 0x100000001b3
    }
    return hash
}
