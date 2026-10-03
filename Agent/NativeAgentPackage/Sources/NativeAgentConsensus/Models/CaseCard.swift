import Foundation

public struct CaseCard: Codable, Sendable, Equatable {
    public let id: String
    public let createdAt: Date
    public let runID: String
    public let title: String
    public let objective: String
    public let primaryClass: String
    public let fingerprint: String
    public let symptoms: [String]
    public let tags: [String]
    public let facets: [String: String]
    public let chosenResolution: String
    public let resolutionSteps: [String]
    public let verificationChecks: [String]
    public let rejectedAlternatives: [String]
    public let outcome: String
    public let searchText: String

    public init(
        id: String,
        createdAt: Date,
        runID: String,
        title: String,
        objective: String,
        primaryClass: String = "",
        fingerprint: String = "",
        symptoms: [String] = [],
        tags: [String] = [],
        facets: [String: String] = [:],
        chosenResolution: String,
        resolutionSteps: [String] = [],
        verificationChecks: [String] = [],
        rejectedAlternatives: [String] = [],
        outcome: String,
        searchText: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.runID = runID
        self.title = title
        self.objective = objective
        self.primaryClass = primaryClass
        self.fingerprint = fingerprint
        self.symptoms = symptoms
        self.tags = tags
        self.facets = facets
        self.chosenResolution = chosenResolution
        self.resolutionSteps = resolutionSteps
        self.verificationChecks = verificationChecks
        self.rejectedAlternatives = rejectedAlternatives
        self.outcome = outcome
        self.searchText = searchText
    }
}
