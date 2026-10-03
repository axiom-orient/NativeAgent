import Foundation
import KnowledgeCore

public struct WikiProjectionSeed: Sendable, Equatable, Codable {
    public var slug: String
    public var title: String
    public var projectionKind: ProjectionKind
    public var subjectKind: String
    public var subjectID: String
    public var authorityIDs: [String]
    public var claimIDs: [String]
    public var bodySeed: String?

    public init(
        slug: String,
        title: String,
        projectionKind: ProjectionKind,
        subjectKind: String,
        subjectID: String,
        authorityIDs: [String] = [],
        claimIDs: [String] = [],
        bodySeed: String? = nil
    ) {
        self.slug = slug
        self.title = title
        self.projectionKind = projectionKind
        self.subjectKind = subjectKind
        self.subjectID = subjectID
        self.authorityIDs = authorityIDs
        self.claimIDs = claimIDs
        self.bodySeed = bodySeed
    }
}
