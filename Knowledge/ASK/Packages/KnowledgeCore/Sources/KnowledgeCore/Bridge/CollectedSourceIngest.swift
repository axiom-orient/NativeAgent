import Foundation

public func toIngestEvidenceRequest(
    _ input: CollectedSource,
    domain: String,
    requestedAt: String,
    focusPrompt: String? = nil
) throws -> IngestEvidenceRequest {
    try input.validate()
    try requireNonEmpty("domain", domain)
    try requireNonEmpty("requested_at", requestedAt)

    let sortedFragments = input.fragments.sortedByOrdinal()
    let fragments = sortedFragments.map { fragment in
        SourceFragment(
            version: sourceFragmentVersion,
            fragmentID: fragment.fragmentID,
            sourceID: input.sourceID,
            ordinal: fragment.ordinal,
            locator: fragment.locator,
            text: fragment.text,
            fingerprint: fragment.fingerprint,
            metadata: fragment.metadata
        )
    }

    let request = IngestEvidenceRequest(
        version: ingestEvidenceRequestVersion,
        source: SourceReceipt(
            version: sourceReceiptVersion,
            sourceID: input.sourceID,
            connector: input.connector,
            sourceKind: input.sourceKind,
            title: input.title,
            observedAt: input.observedAt,
            capturedAt: input.capturedAt,
            canonicalURI: sourceURI(input.sourceID),
            contentHash: input.contentHash,
            rawRelpath: input.rawRelpath,
            mimeType: input.mimeType,
            language: input.language,
            tags: input.tags,
            metadata: normalizedCollectedSourceMetadata(input, sortedFragments: sortedFragments)
        ),
        fragments: fragments,
        domain: domain,
        requestedAt: requestedAt,
        focusPrompt: focusPrompt
    )
    try request.validate()
    return request
}
