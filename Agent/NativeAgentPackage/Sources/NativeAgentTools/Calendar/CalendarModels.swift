import Foundation
import NativeAgentDomain

public struct CalendarEventRecord: Codable, Sendable, Equatable, Hashable {
    public let identifier: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let location: String?
    public let notes: String?
    public let isAllDay: Bool
    public let revision: String?

    public init(
        identifier: String,
        title: String,
        startDate: Date,
        endDate: Date,
        location: String? = nil,
        notes: String? = nil,
        isAllDay: Bool = false,
        revision: String? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.notes = notes
        self.isAllDay = isAllDay
        self.revision = revision
    }
}

public struct CalendarEventDraft: Codable, Sendable, Equatable, Hashable {
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let location: String?
    public let notes: String?
    public let isAllDay: Bool

    public init(
        title: String,
        startDate: Date,
        endDate: Date,
        location: String? = nil,
        notes: String? = nil,
        isAllDay: Bool = false
    ) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.notes = notes
        self.isAllDay = isAllDay
    }
}

extension CalendarEventDraft {
    var normalizedForStorage: CalendarEventDraft {
        CalendarEventDraft(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            startDate: startDate,
            endDate: endDate,
            location: location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            isAllDay: isAllDay
        )
    }
}

public struct CalendarEventPage: Sendable, Equatable {
    public let events: [CalendarEventRecord]
    public let nextCursor: String?

    public init(events: [CalendarEventRecord], nextCursor: String? = nil) {
        self.events = events
        self.nextCursor = nextCursor
    }
}

public protocol CalendarEventVerificationService: Sendable {
    /// Returns the current authoritative event state, or nil when the event no longer exists.
    func event(identifier: String) async throws -> CalendarEventRecord?
}

public protocol CalendarToolService: Sendable {
    /// `cursor` is provider-owned and must be rejected when it does not belong
    /// to the supplied date range. A non-nil `nextCursor` means another bounded
    /// call can continue the same logical query.
    func listEvents(
        startDate: Date,
        endDate: Date,
        limit: Int,
        cursor: String?
    ) async throws -> CalendarEventPage
    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEventRecord
    func updateEvent(identifier: String, draft: CalendarEventDraft) async throws -> CalendarEventRecord
    func deleteEvent(identifier: String) async throws
}

enum CalendarListPolicy {
    static let maximumPageSize = 100
    static let maximumCursorBytes = 4_096
}

func validateDateRange(startDate: Date, endDate: Date) throws {
    guard startDate.timeIntervalSinceReferenceDate.isFinite,
          endDate.timeIntervalSinceReferenceDate.isFinite,
          endDate > startDate else {
        throw AgentError.invalidToolCall("endDate must be later than startDate.")
    }
}

func validateCalendarEventDraft(_ draft: CalendarEventDraft) throws {
    guard draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        throw AgentError.invalidToolCall("Calendar event title must not be empty.")
    }
    try validateDateRange(startDate: draft.startDate, endDate: draft.endDate)
}
