import Foundation
import NativeAgentDomain

struct CalendarListEventsRequest: Sendable, Equatable {
    let startDate: Date
    let endDate: Date
    let limit: Int
    let cursor: String?

    init(arguments: JSONValue) throws {
        let object = try requiredObject(arguments, toolName: "calendar.listEvents")
        try rejectUnknownKeys(
            object,
            allowed: ["startDate", "endDate", "limit", "cursor"],
            toolName: "calendar.listEvents"
        )
        self.startDate = try parseNativeAgentISO8601Date(try arguments.stringField("startDate"))
        self.endDate = try parseNativeAgentISO8601Date(try arguments.stringField("endDate"))
        let limit = try optionalBoundedInt(
            object["limit"],
            field: "limit",
            defaultValue: 50,
            range: 1...CalendarListPolicy.maximumPageSize,
            toolName: "calendar.listEvents"
        )
        self.limit = limit
        self.cursor = try optionalCursor(object["cursor"])
        try validateDateRange(startDate: startDate, endDate: endDate)
    }
}

private func optionalCursor(_ value: JSONValue?) throws -> String? {
    guard let value else { return nil }
    guard let cursor = value.stringValue else {
        throw AgentError.invalidToolCall("Calendar list cursor must be a string.")
    }
    guard cursor.isEmpty == false,
          cursor.utf8.count <= CalendarListPolicy.maximumCursorBytes else {
        throw AgentError.invalidToolCall("Calendar list cursor is invalid.")
    }
    return cursor
}

struct CalendarCreateEventRequest: Sendable, Equatable {
    let draft: CalendarEventDraft

    init(arguments: JSONValue) throws {
        let draft = try calendarDraft(arguments: arguments)
        try validateCalendarEventDraft(draft)
        self.draft = draft
    }
}

struct CalendarUpdateEventRequest: Sendable, Equatable {
    let identifier: String
    let expectedRevision: String?
    let draft: CalendarEventDraft

    init(arguments: JSONValue) throws {
        let identifier = try arguments.stringField("identifier")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.isEmpty == false else {
            throw AgentError.invalidToolCall("Calendar event identifier must not be empty.")
        }
        let draft = try calendarDraft(arguments: arguments)
        try validateCalendarEventDraft(draft)
        self.identifier = identifier
        self.expectedRevision = try optionalCalendarRevision(arguments.objectValue?["expectedRevision"])
        self.draft = draft
    }
}

struct CalendarDeleteEventRequest: Sendable, Equatable {
    let identifier: String
    let expectedRevision: String?

    init(arguments: JSONValue) throws {
        let identifier = try arguments.stringField("identifier")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.isEmpty == false else {
            throw AgentError.invalidToolCall("Calendar event identifier must not be empty.")
        }
        self.identifier = identifier
        self.expectedRevision = try optionalCalendarRevision(arguments.objectValue?["expectedRevision"])
    }
}

private func optionalCalendarRevision(_ value: JSONValue?) throws -> String? {
    guard let value else { return nil }
    guard let revision = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
          revision.isEmpty == false,
          revision.utf8.count <= 512 else {
        throw AgentError.invalidToolCall("expectedRevision must be a non-empty string up to 512 UTF-8 bytes.")
    }
    return revision
}

private func calendarDraft(arguments: JSONValue) throws -> CalendarEventDraft {
    let isAllDay: Bool
    if let value = arguments.objectValue?["isAllDay"] {
        guard let bool = value.boolValue else {
            throw AgentError.invalidToolCall("Field isAllDay must be a boolean.")
        }
        isAllDay = bool
    } else {
        isAllDay = false
    }

    return CalendarEventDraft(
        title: try arguments.stringField("title"),
        startDate: try parseNativeAgentISO8601Date(try arguments.stringField("startDate")),
        endDate: try parseNativeAgentISO8601Date(try arguments.stringField("endDate")),
        location: arguments.optionalStringField("location"),
        notes: arguments.optionalStringField("notes"),
        isAllDay: isAllDay
    )
}
