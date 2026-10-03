import Foundation

package enum ASKWorkWikiConvergence {
    private static let removableTopicTokens: Set<String> = [
        "research", "prepare", "prepared", "plan", "plans", "proof", "prove", "proved", "docs", "doc", "note", "notes"
    ]

    package static func build(project: ASKWorkWikiProjectResolution, documents: [ASKWorkWikiIndexedDocument]) -> ASKWorkWikiConvergenceReport {
        var buckets: [String: TopicAccumulator] = [:]

        for document in documents {
            guard let phase = phase(for: document.category) else { continue }
            let topic = topicIdentity(for: document)
            var bucket = buckets[topic.slug] ?? TopicAccumulator(topicSlug: topic.slug, topicTitle: topic.title)
            bucket.register(phase)
            buckets[topic.slug] = bucket
        }

        let topics = buckets.values
            .map { $0.makeTopic() }
            .sorted { lhs, rhs in
                if lhs.coveragePercent != rhs.coveragePercent {
                    return lhs.coveragePercent > rhs.coveragePercent
                }
                return lhs.topicSlug < rhs.topicSlug
            }

        return ASKWorkWikiConvergenceReport(project: project, topics: topics)
    }

    private static func phase(for category: ASKWorkWikiKnowledgeCategory) -> Phase? {
        switch category {
        case .research: .research
        case .prepare: .prepare
        case .prove: .prove
        case .docs: .docs
        case .onit: nil
        }
    }

    private static func topicIdentity(for document: ASKWorkWikiIndexedDocument) -> (slug: String, title: String) {
        let stem = URL(fileURLWithPath: document.relativePath).deletingPathExtension().lastPathComponent
        let rawTokens = normalizedTokens(stem)
        let filteredTokens = rawTokens.filter { removableTopicTokens.contains($0) == false }
        let stableTokens = filteredTokens.isEmpty ? rawTokens : filteredTokens
        let slug = stableTokens.isEmpty ? "topic" : stableTokens.joined(separator: "-")
        let title = stableTokens.isEmpty ? document.title : stableTokens.map(titleCase).joined(separator: " ")
        return (slug, title)
    }

    private static func normalizedTokens(_ value: String) -> [String] {
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        return String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func titleCase(_ value: String) -> String {
        value.prefix(1).uppercased() + value.dropFirst()
    }
}

private enum Phase {
    case research
    case prepare
    case prove
    case docs
}

private struct TopicAccumulator {
    var topicSlug: String
    var topicTitle: String
    var researchCount = 0
    var prepareCount = 0
    var proveCount = 0
    var docsCount = 0

    mutating func register(_ phase: Phase) {
        switch phase {
        case .research: researchCount += 1
        case .prepare: prepareCount += 1
        case .prove: proveCount += 1
        case .docs: docsCount += 1
        }
    }

    func makeTopic() -> ASKWorkWikiConvergenceTopic {
        let coveredPhases = [researchCount, prepareCount, proveCount, docsCount].filter { $0 > 0 }.count
        let coveragePercent = coveredPhases * 25
        let strength: ASKWorkWikiConvergenceStrength
        switch coveredPhases {
        case 4:
            strength = .full
        case 2, 3:
            strength = .partial
        default:
            strength = .weak
        }
        return ASKWorkWikiConvergenceTopic(
            topicSlug: topicSlug,
            topicTitle: topicTitle,
            researchCount: researchCount,
            prepareCount: prepareCount,
            proveCount: proveCount,
            docsCount: docsCount,
            coveragePercent: coveragePercent,
            strength: strength
        )
    }
}
