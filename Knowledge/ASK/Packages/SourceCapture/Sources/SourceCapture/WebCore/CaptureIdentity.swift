import Foundation
import KnowledgeCore

public func webSHA256Prefixed(_ data: Data) -> String {
    ASKSHA256.prefixedDigest(data)
}

public func shortFingerprint(_ text: String) -> String {
    String(ASKSHA256.hexDigest(Data(text.utf8)).prefix(16))
}

public func inferDomainTag(from urlString: String) -> String? {
    guard let host = URL(string: urlString)?.host?.lowercased(), !host.isEmpty else { return nil }
    let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    return trimmed.replacingOccurrences(of: ".", with: "-")
}

public func defaultRawRelpath(sourceID: String, observedAt: String, fileExtension: String = "html") -> String {
    let datePart = String(observedAt.prefix(10))
    let parts = datePart.split(separator: "-")
    let year = parts.count > 0 ? String(parts[0]) : "1970"
    let month = parts.count > 1 ? String(parts[1]) : "01"
    let slug = sourceID.replacingOccurrences(of: "_", with: "-")
    return "raw/evidence/\(year)/\(month)/\(slug).\(fileExtension)"
}
