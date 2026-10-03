import Foundation

public struct ContactRecord: Codable, Sendable, Equatable, Hashable {
    public let identifier: String
    public let givenName: String
    public let familyName: String
    public let organizationName: String
    public let emailAddresses: [String]
    public let phoneNumbers: [String]

    public init(
        identifier: String,
        givenName: String,
        familyName: String,
        organizationName: String = "",
        emailAddresses: [String] = [],
        phoneNumbers: [String] = []
    ) {
        self.identifier = identifier
        self.givenName = givenName
        self.familyName = familyName
        self.organizationName = organizationName
        self.emailAddresses = emailAddresses
        self.phoneNumbers = phoneNumbers
    }
}

public struct ContactsPage: Sendable, Equatable {
    public let contacts: [ContactRecord]
    public let nextCursor: String?

    public init(contacts: [ContactRecord], nextCursor: String? = nil) {
        self.contacts = contacts
        self.nextCursor = nextCursor
    }
}

public protocol ContactsToolService: Sendable {
    /// The provider owns cursor encoding and must reject a cursor that does not
    /// belong to the normalized query.
    func search(query: String, limit: Int, cursor: String?) async throws -> ContactsPage
}
