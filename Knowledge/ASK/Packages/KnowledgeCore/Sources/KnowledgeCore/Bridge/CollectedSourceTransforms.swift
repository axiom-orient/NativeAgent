import Foundation

public let searchableTextVersion = "ask-searchable-text.v1"

public func normalizedCollectedSourceMetadata(_ input: CollectedSource) -> ASKFields {
    normalizedCollectedSourceMetadata(input, sortedFragments: input.fragments.sortedByOrdinal())
}

public func normalizedCollectedSourceMetadata(_ input: CollectedSource, sortedFragments: [CollectedFragment]) -> ASKFields {
    var metadata = input.metadata
    let searchableText = _canonicalSearchableText(title: input.title, metadata: input.metadata, sortedFragments: sortedFragments)
    if !searchableText.isEmpty {
        metadata["searchable_text"] = searchableText
        metadata["searchable_text_version"] = searchableTextVersion
        metadata["searchable_text_length"] = String(searchableText.count)
    }
    return metadata
}

public func canonicalSearchableText(for input: CollectedSource) -> String {
    _canonicalSearchableText(title: input.title, metadata: input.metadata, sortedFragments: input.fragments.sortedByOrdinal())
}

private func _canonicalSearchableText(title: String, metadata: ASKFields, sortedFragments: [CollectedFragment]) -> String {
    let fragmentText = sortedFragments
        .map(\.text)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")

    let parts = [
        title,
        metadata["description"] ?? "",
        metadata["canonical_url"] ?? "",
        metadata["final_url"] ?? "",
        metadata["curated_note_excerpt"] ?? "",
        fragmentText,
        metadata["site_name"] ?? "",
    ]
    return parts
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}
