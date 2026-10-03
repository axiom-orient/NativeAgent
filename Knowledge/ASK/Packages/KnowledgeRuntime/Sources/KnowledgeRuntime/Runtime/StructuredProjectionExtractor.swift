import Foundation
import KnowledgeCore

private let entityRegexes: Result<[NSRegularExpression], Error> = Result {
    [
        try NSRegularExpression(pattern: #"\b[A-Z][A-Z0-9-]{1,}\b"#),
        try NSRegularExpression(pattern: #"\b(?:[A-Z][A-Za-z0-9-]*)(?:[- ][A-Z][A-Za-z0-9-]*)+\b"#),
    ]
}

private enum StructuredProjectionExtractorConfig {
    static let maxTopicSeeds = 4
    static let maxEntitySeeds = 4
    static let maxCurrentSeeds = 3

    static let structuralHeadingStoplist: Set<String> = [
        "about",
        "conclusion",
        "details",
        "evidence",
        "faq",
        "introduction",
        "overview",
        "references",
        "related",
        "source",
        "summary",
    ]
}

private struct SeedOccurrence {
    var title: String
    var seenInTitle = false
    var fragmentOrdinals = Set<Int>()
    var headingOrdinals = Set<Int>()

    var evidenceWeight: Int {
        (seenInTitle ? 3 : 0) + fragmentOrdinals.count * 2 + headingOrdinals.count
    }
}

private struct CurrentSeedGroup {
    var subjectKind: String
    var subjectID: String
    var authorityIDs = Set<String>()
    var factScopes = Set<String>()
    var titles = Set<String>()
    var claimIDs = Set<String>()
}

package func automaticProjectionSeeds(
    store: KnowledgeStore,
    source: SourceReceipt
) throws -> [WikiProjectionSeed] {
    let fragments = orderedSourceFragments(for: source.sourceID, store: store)
    let topicSeeds = automaticTopicSeeds(source: source, fragments: fragments)
    let entitySeeds = try automaticEntitySeeds(source: source, fragments: fragments, topicSeeds: topicSeeds)
    let currentSeeds = automaticCurrentSeeds(store: store, source: source, topicSeeds: topicSeeds, entitySeeds: entitySeeds)
    return topicSeeds + entitySeeds + currentSeeds
}


private func automaticTopicSeeds(source: SourceReceipt, fragments: [SourceFragment]) -> [WikiProjectionSeed] {
    var occurrencesBySlug: [String: SeedOccurrence] = [:]

    for tag in source.tags {
        guard let slug = seedLeaf(for: tag) else { continue }
        recordOccurrence(
            slug: slug,
            title: preferredSeedTitle(raw: tag, slug: slug),
            ordinal: nil,
            bucket: .fragment,
            occurrencesBySlug: &occurrencesBySlug
        )
    }

    for fragment in fragments {
        for heading in fragmentHeadings(fragment) {
            guard let slug = seedLeaf(for: heading) else { continue }
            if StructuredProjectionExtractorConfig.structuralHeadingStoplist.contains(slug) { continue }
            recordOccurrence(
                slug: slug,
                title: preferredSeedTitle(raw: heading, slug: slug),
                ordinal: fragment.ordinal,
                bucket: .heading,
                occurrencesBySlug: &occurrencesBySlug
            )
        }
    }

    return Array(occurrencesBySlug
        .map { slug, occurrence in
            WikiProjectionSeed(
                slug: slug,
                title: occurrence.title,
                projectionKind: .topicOverview,
                subjectKind: "topic",
                subjectID: slug,
                authorityIDs: [],
                claimIDs: [],
                bodySeed: nil
            )
        }
        .sorted { lhs, rhs in
            let lhsWeight = occurrencesBySlug[lhs.slug]?.evidenceWeight ?? 0
            let rhsWeight = occurrencesBySlug[rhs.slug]?.evidenceWeight ?? 0
            if lhsWeight != rhsWeight { return lhsWeight > rhsWeight }
            return lhs.slug < rhs.slug
        }
        .prefix(StructuredProjectionExtractorConfig.maxTopicSeeds)
    )
}

private func automaticEntitySeeds(
    source: SourceReceipt,
    fragments: [SourceFragment],
    topicSeeds: [WikiProjectionSeed]
) throws -> [WikiProjectionSeed] {
    let topicSlugs = Set(topicSeeds.map(\.slug))
    var occurrencesBySlug: [String: SeedOccurrence] = [:]

    for phrase in try entityPhraseCandidates(in: source.title) {
        guard let slug = seedLeaf(for: phrase), !topicSlugs.contains(slug) else { continue }
        recordOccurrence(
            slug: slug,
            title: preferredSeedTitle(raw: phrase, slug: slug),
            ordinal: nil,
            bucket: .title,
            occurrencesBySlug: &occurrencesBySlug
        )
    }

    for fragment in fragments {
        var phrases = try entityPhraseCandidates(in: fragment.text)
        for heading in fragmentHeadings(fragment) {
            phrases.append(contentsOf: try entityPhraseCandidates(in: heading))
        }
        for phrase in phrases {
            guard let slug = seedLeaf(for: phrase), !topicSlugs.contains(slug) else { continue }
            recordOccurrence(
                slug: slug,
                title: preferredSeedTitle(raw: phrase, slug: slug),
                ordinal: fragment.ordinal,
                bucket: .fragment,
                occurrencesBySlug: &occurrencesBySlug
            )
        }
    }

    let seeds = Array(occurrencesBySlug
        .filter { slug, occurrence in
            let phrase = occurrence.title
            if StructuredProjectionExtractorConfig.structuralHeadingStoplist.contains(slug) { return false }
            let seenAcrossFragments = occurrence.fragmentOrdinals.count >= 2 || occurrence.headingOrdinals.count >= 2
            let seenInTitleAndBody = occurrence.seenInTitle && (!occurrence.fragmentOrdinals.isEmpty || !occurrence.headingOrdinals.isEmpty)
            let repeatedAcronym = isAcronymPhrase(phrase) && occurrence.evidenceWeight >= 5
            return seenAcrossFragments || seenInTitleAndBody || repeatedAcronym
        }
        .map { slug, occurrence in
            WikiProjectionSeed(
                slug: slug,
                title: occurrence.title,
                projectionKind: .entityOverview,
                subjectKind: "entity",
                subjectID: slug,
                authorityIDs: [],
                claimIDs: [],
                bodySeed: nil
            )
        }
        .sorted { lhs, rhs in
            let lhsWeight = occurrencesBySlug[lhs.slug]?.evidenceWeight ?? 0
            let rhsWeight = occurrencesBySlug[rhs.slug]?.evidenceWeight ?? 0
            if lhsWeight != rhsWeight { return lhsWeight > rhsWeight }
            return lhs.slug < rhs.slug
        }
        .prefix(StructuredProjectionExtractorConfig.maxEntitySeeds)
    )

    return seeds
}

private func automaticCurrentSeeds(
    store: KnowledgeStore,
    source: SourceReceipt,
    topicSeeds: [WikiProjectionSeed],
    entitySeeds: [WikiProjectionSeed]
) -> [WikiProjectionSeed] {
    var candidateSubjectIDs = Set(topicSeeds.map(\.subjectID))
    candidateSubjectIDs.formUnion(entitySeeds.map(\.subjectID))
    candidateSubjectIDs.formUnion(source.tags.compactMap(seedLeaf(for:)))
    if let titleSlug = seedLeaf(for: source.title) {
        candidateSubjectIDs.insert(titleSlug)
    }

    let claimsByAuthorityID = Dictionary(grouping: store.claims.values.compactMap { claim -> (String, ClaimRecord)? in
        guard let authorityRecordID = claim.authorityRecordID else { return nil }
        return (authorityRecordID, claim)
    }, by: \.0).mapValues { pairs in pairs.map(\.1) }
    let claimsBySubject = Dictionary(grouping: store.claims.values) { claim in
        claim.subjectKind + "::" + claim.subjectID
    }

    var grouped: [String: CurrentSeedGroup] = [:]
    for record in store.authorityRecords.values where record.approvalState == .approved {
        guard candidateSubjectIDs.contains(record.subjectID) else { continue }
        let key = record.subjectKind + "::" + record.subjectID
        var group = grouped[key] ?? CurrentSeedGroup(subjectKind: record.subjectKind, subjectID: record.subjectID)
        group.authorityIDs.insert(record.recordID)
        group.factScopes.insert(record.factScopeKey)
        if let name = record.valueFields["name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            group.titles.insert(name)
        }
        let matchingClaims = ((claimsByAuthorityID[record.recordID] ?? []) + (claimsBySubject[key] ?? [])).map(\.claimID)
        group.claimIDs.formUnion(matchingClaims)
        grouped[key] = group
    }

    return Array(grouped.values
        .map { group in
            let preferredTitle = group.titles.sorted().first ?? preferredCurrentTitle(subjectID: group.subjectID, entitySeeds: entitySeeds, topicSeeds: topicSeeds)
            let bodySeed = group.factScopes.isEmpty ? nil : "Approved authority scopes: " + group.factScopes.sorted().joined(separator: ", ")
            return WikiProjectionSeed(
                slug: group.subjectID,
                title: preferredTitle,
                projectionKind: .currentSnapshot,
                subjectKind: group.subjectKind,
                subjectID: group.subjectID,
                authorityIDs: group.authorityIDs.sorted(),
                claimIDs: group.claimIDs.sorted(),
                bodySeed: bodySeed
            )
        }
        .sorted { lhs, rhs in
            if lhs.authorityIDs.count != rhs.authorityIDs.count { return lhs.authorityIDs.count > rhs.authorityIDs.count }
            return lhs.slug < rhs.slug
        }
        .prefix(StructuredProjectionExtractorConfig.maxCurrentSeeds)
    )
}

private enum OccurrenceBucket {
    case title
    case heading
    case fragment
}

private func recordOccurrence(
    slug: String,
    title: String,
    ordinal: Int?,
    bucket: OccurrenceBucket,
    occurrencesBySlug: inout [String: SeedOccurrence]
) {
    var occurrence = occurrencesBySlug[slug] ?? SeedOccurrence(title: title)
    if occurrence.title.isEmpty {
        occurrence.title = title
    }
    switch bucket {
    case .title:
        occurrence.seenInTitle = true
    case .heading:
        if let ordinal { occurrence.headingOrdinals.insert(ordinal) }
    case .fragment:
        if let ordinal { occurrence.fragmentOrdinals.insert(ordinal) }
    }
    occurrencesBySlug[slug] = occurrence
}

private func fragmentHeadings(_ fragment: SourceFragment) -> [String] {
    [fragment.locator["heading"], fragment.metadata["heading"]]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private func entityPhraseCandidates(in text: String) throws -> [String] {
    let content = text as NSString
    let range = NSRange(location: 0, length: content.length)
    var output: [String] = []
    var seen = Set<String>()
    for regex in try entityRegexes.get() {
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let phraseRange = Range(match.range, in: text) else { return }
            let phrase = text[phraseRange].trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizeSeedKey(phrase)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            output.append(phrase)
        }
    }
    return output
}

private func seedLeaf(for value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let transliterated = trimmed.applyingTransform(.toLatin, reverse: false) ?? trimmed
    let stripped = transliterated.applyingTransform(.stripCombiningMarks, reverse: false) ?? transliterated
    let lowercased = stripped.lowercased()
    let slug = lowercased
        .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    guard !slug.isEmpty else { return nil }
    guard slug != "current", slug != "entity", slug != "topic", slug != "query" else { return nil }
    return slug
}

private func preferredSeedTitle(raw: String, slug: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return slugTitle(slug) }
    let collapsed = trimmed.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return collapsed.isEmpty ? slugTitle(slug) : collapsed
}

private func preferredCurrentTitle(
    subjectID: String,
    entitySeeds: [WikiProjectionSeed],
    topicSeeds: [WikiProjectionSeed]
) -> String {
    if let entity = entitySeeds.first(where: { $0.subjectID == subjectID }) {
        return entity.title
    }
    if let topic = topicSeeds.first(where: { $0.subjectID == subjectID }) {
        return topic.title
    }
    return slugTitle(subjectID)
}

private func normalizeSeedKey(_ value: String) -> String {
    value
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func isAcronymPhrase(_ value: String) -> Bool {
    let compact = value.replacingOccurrences(of: "-", with: "")
    guard !compact.isEmpty else { return false }
    return compact.unicodeScalars.allSatisfy { scalar in
        let ch = Character(scalar)
        return scalar.isASCII && (ch.isUppercase || ch.isNumber)
    }
}
