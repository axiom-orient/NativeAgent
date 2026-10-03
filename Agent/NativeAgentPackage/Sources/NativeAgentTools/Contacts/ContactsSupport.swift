import Foundation
import NativeAgentDomain

struct ContactSearchMatcher: Sendable, Equatable {
    let normalizedQuery: String

    init(query: String) {
        self.normalizedQuery = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    var isEmpty: Bool {
        normalizedQuery.isEmpty
    }

    func matches(record: ContactRecord) -> Bool {
        let haystack = [
            record.givenName,
            record.familyName,
            record.organizationName
        ] + record.emailAddresses + record.phoneNumbers

        return haystack.contains { field in
            field.lowercased().contains(normalizedQuery)
        }
    }
}

func contactsOutput(_ page: ContactsPage) -> JSONValue {
    .object([
        "contacts": .array(page.contacts.map(contactObject(_:))),
        "nextCursor": page.nextCursor.map(JSONValue.string) ?? .null,
        "hasMore": .bool(page.nextCursor != nil)
    ])
}

private func contactObject(_ record: ContactRecord) -> JSONValue {
    .object([
        "identifier": .string(record.identifier),
        "givenName": .string(record.givenName),
        "familyName": .string(record.familyName),
        "organizationName": .string(record.organizationName),
        "emailAddresses": .array(record.emailAddresses.map(JSONValue.string)),
        "phoneNumbers": .array(record.phoneNumbers.map(JSONValue.string))
    ])
}
