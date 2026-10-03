import Foundation
import NativeAgentDomain

struct ContactsSearchRequest: Sendable, Equatable {
    static let maximumPageSize = 50
    static let maximumCursorBytes = 4_096

    let query: String
    let limit: Int
    let cursor: String?

    init(arguments: JSONValue, maximumLimit: Int = maximumPageSize) throws {
        let object = try requiredObject(arguments, toolName: "contacts.search")
        try rejectUnknownKeys(
            object,
            allowed: ["query", "limit", "cursor"],
            toolName: "contacts.search"
        )
        let query = try arguments.stringField("query")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else {
            throw AgentError.invalidToolCall("contacts.search query must not be empty.")
        }
        self.query = query
        let requestedLimit = try optionalBoundedInt(
            object["limit"],
            field: "limit",
            defaultValue: 10,
            range: 1...maximumLimit,
            toolName: "contacts.search"
        )
        self.limit = requestedLimit

        if let value = object["cursor"] {
            guard let cursor = value.stringValue,
                  cursor.isEmpty == false,
                  cursor.utf8.count <= Self.maximumCursorBytes else {
                throw AgentError.invalidToolCall("contacts.search cursor is invalid.")
            }
            self.cursor = cursor
        } else {
            self.cursor = nil
        }
    }
}
