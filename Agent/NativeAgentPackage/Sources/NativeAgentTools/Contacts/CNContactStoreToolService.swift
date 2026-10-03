import Foundation
import NativeAgentDomain

#if canImport(Contacts)
import Contacts

@available(iOS 17, *)
public actor CNContactStoreToolService: ContactsToolService {
    private let store = CNContactStore()

    public init() {}

    public func search(
        query: String,
        limit: Int,
        cursor: String?
    ) async throws -> ContactsPage {
        let matcher = ContactSearchMatcher(query: query)
        guard matcher.isEmpty == false else {
            throw AgentError.invalidToolCall("contacts.search query must not be empty.")
        }
        guard 1...ContactsSearchRequest.maximumPageSize ~= limit else {
            throw AgentError.invalidToolCall("contacts.search page size must be between 1 and 50.")
        }
        let decodedCursor = try decodeCursor(cursor, query: matcher.normalizedQuery)
        try requireHostUsageDescription(
            "NSContactsUsageDescription",
            capability: "Contacts access"
        )

        let granted = try await requestAccess()
        guard granted else {
            throw AgentError.accessDenied("Contacts access was denied.")
        }
        let historyToken = store.currentHistoryToken
        if let decodedCursor, decodedCursor.historyToken != historyToken {
            throw AgentError.invalidToolCall("Contacts changed since the preceding page; restart this search.")
        }
        let offset = decodedCursor?.offset ?? 0

        let request = CNContactFetchRequest(keysToFetch: contactKeys)
        request.sortOrder = .userDefault

        var matchesSeen = 0
        var results: [ContactRecord] = []
        results.reserveCapacity(limit + 1)

        try store.enumerateContacts(with: request) { contact, stop in
            let record = contactRecord(from: contact)
            guard matcher.matches(record: record) else {
                return
            }

            if matchesSeen < offset {
                matchesSeen += 1
                return
            }

            results.append(record)
            if results.count > limit {
                stop.pointee = true
            }
        }
        guard store.currentHistoryToken == historyToken else {
            throw AgentError.invalidToolCall(
                "Contacts changed while this page was being read; restart this search."
            )
        }

        let hasMore = results.count > limit
        return ContactsPage(
            contacts: Array(results.prefix(limit)),
            nextCursor: hasMore
                ? try encodeCursor(
                    offset: offset + limit,
                    query: matcher.normalizedQuery,
                    historyToken: historyToken
                )
                : nil
        )
    }

    private struct ContactsCursor: Codable {
        let version: Int
        let query: String
        let offset: Int
        let historyToken: Data?
    }

    private func decodeCursor(_ cursor: String?, query: String) throws -> ContactsCursor? {
        guard let cursor else { return nil }
        guard cursor.utf8.count <= ContactsSearchRequest.maximumCursorBytes,
              let data = Data(base64Encoded: cursor),
              let value = try? JSONDecoder().decode(ContactsCursor.self, from: data),
              value.version == 1,
              value.query == query,
              value.offset >= 0 else {
            throw AgentError.invalidToolCall("Contacts cursor does not match this query.")
        }
        return value
    }

    private func encodeCursor(offset: Int, query: String, historyToken: Data?) throws -> String {
        let value = ContactsCursor(
            version: 1,
            query: query,
            offset: offset,
            historyToken: historyToken
        )
        let cursor = try JSONEncoder().encode(value).base64EncodedString()
        guard cursor.utf8.count <= ContactsSearchRequest.maximumCursorBytes else {
            throw AgentError.invariantViolation("Contacts cursor exceeded its safety bound.")
        }
        return cursor
    }

    private func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
            store.requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private var contactKeys: [any CNKeyDescriptor] {
        [
            CNContactIdentifierKey as any CNKeyDescriptor,
            CNContactGivenNameKey as any CNKeyDescriptor,
            CNContactFamilyNameKey as any CNKeyDescriptor,
            CNContactOrganizationNameKey as any CNKeyDescriptor,
            CNContactEmailAddressesKey as any CNKeyDescriptor,
            CNContactPhoneNumbersKey as any CNKeyDescriptor
        ]
    }

    private func contactRecord(from contact: CNContact) -> ContactRecord {
        ContactRecord(
            identifier: contact.identifier,
            givenName: contact.givenName,
            familyName: contact.familyName,
            organizationName: contact.organizationName,
            emailAddresses: contact.emailAddresses.map { String($0.value) },
            phoneNumbers: contact.phoneNumbers.map { $0.value.stringValue }
        )
    }
}
#endif
