import Foundation
import NativeAgentDomain

#if canImport(EventKit)
import EventKit

@available(iOS 17, *)
public actor EventKitCalendarToolService: CalendarToolService, CalendarEventVerificationService {
    private let store: EKEventStore

    public init() {
        self.store = EKEventStore()
    }

    public func listEvents(
        startDate: Date,
        endDate: Date,
        limit: Int,
        cursor: String?
    ) async throws -> CalendarEventPage {
        try validateDateRange(startDate: startDate, endDate: endDate)
        guard 1...CalendarListPolicy.maximumPageSize ~= limit else {
            throw AgentError.invalidToolCall("Calendar list page size must be between 1 and 100.")
        }

        try await requireFullAccess()
        var position = try decodeCursor(cursor, startDate: startDate, endDate: endDate)
        var records: [CalendarEventRecord] = []
        records.reserveCapacity(limit)
        var scannedWindows = 0

        while records.count < limit,
              position.windowStart < endDate,
              scannedWindows < Self.maximumWindowsPerPage {
            let windowEnd = min(
                position.windowStart.addingTimeInterval(Self.scanWindow),
                endDate
            )
            let predicate = store.predicateForEvents(
                withStart: position.windowStart,
                end: windowEnd,
                calendars: nil
            )
            let windowRecords = store.events(matching: predicate)
                .filter { position.windowStart == startDate || $0.startDate >= position.windowStart }
                .map(calendarEventRecord(from:))
                .sorted(by: Self.isOrderedBefore)
            guard position.offset <= windowRecords.count else {
                throw AgentError.invalidToolCall("Calendar cursor no longer matches the current event view.")
            }

            let remaining = limit - records.count
            let available = windowRecords.dropFirst(position.offset)
            records.append(contentsOf: available.prefix(remaining))
            let consumed = min(available.count, remaining)

            if position.offset + consumed < windowRecords.count {
                position.offset += consumed
                return CalendarEventPage(
                    events: records,
                    nextCursor: try encodeCursor(position, startDate: startDate, endDate: endDate)
                )
            }

            position = EventCursorPosition(windowStart: windowEnd, offset: 0)
            scannedWindows += 1
        }

        return CalendarEventPage(
            events: records,
            nextCursor: position.windowStart < endDate
                ? try encodeCursor(position, startDate: startDate, endDate: endDate)
                : nil
        )
    }

    private static let scanWindow: TimeInterval = 31 * 24 * 60 * 60
    private static let maximumWindowsPerPage = 12

    private struct EventCursorPosition: Codable {
        let windowStart: Date
        var offset: Int
    }

    private struct EventCursorEnvelope: Codable {
        let version: Int
        let startDate: Date
        let endDate: Date
        let position: EventCursorPosition
    }

    private func decodeCursor(
        _ cursor: String?,
        startDate: Date,
        endDate: Date
    ) throws -> EventCursorPosition {
        guard let cursor else {
            return EventCursorPosition(windowStart: startDate, offset: 0)
        }
        guard cursor.utf8.count <= CalendarListPolicy.maximumCursorBytes,
              let data = Data(base64Encoded: cursor),
              let envelope = try? JSONDecoder().decode(EventCursorEnvelope.self, from: data),
              envelope.version == 1,
              envelope.startDate == startDate,
              envelope.endDate == endDate,
              envelope.position.windowStart >= startDate,
              envelope.position.windowStart <= endDate,
              envelope.position.offset >= 0 else {
            throw AgentError.invalidToolCall("Calendar cursor does not match this date range.")
        }
        return envelope.position
    }

    private func encodeCursor(
        _ position: EventCursorPosition,
        startDate: Date,
        endDate: Date
    ) throws -> String {
        let envelope = EventCursorEnvelope(
            version: 1,
            startDate: startDate,
            endDate: endDate,
            position: position
        )
        let cursor = try JSONEncoder().encode(envelope).base64EncodedString()
        guard cursor.utf8.count <= CalendarListPolicy.maximumCursorBytes else {
            throw AgentError.invariantViolation("Calendar cursor exceeded its safety bound.")
        }
        return cursor
    }

    private static func isOrderedBefore(
        _ lhs: CalendarEventRecord,
        _ rhs: CalendarEventRecord
    ) -> Bool {
        if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
        if lhs.endDate != rhs.endDate { return lhs.endDate < rhs.endDate }
        return lhs.identifier < rhs.identifier
    }

    public func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEventRecord {
        try validateCalendarEventDraft(draft)
        try await requireWriteAccess()

        let event = EKEvent(eventStore: store)
        event.calendar = store.defaultCalendarForNewEvents
        apply(draft, to: event)
        try store.save(event, span: .thisEvent, commit: true)
        return calendarEventRecord(from: event)
    }

    public func updateEvent(
        identifier: String,
        draft: CalendarEventDraft
    ) async throws -> CalendarEventRecord {
        try validateCalendarEventDraft(draft)
        try await requireFullAccess()
        let event = try existingEvent(identifier: identifier)
        apply(draft, to: event)
        try store.save(event, span: .thisEvent, commit: true)
        return calendarEventRecord(from: event)
    }

    public func deleteEvent(identifier: String) async throws {
        try await requireFullAccess()
        let event = try existingEvent(identifier: identifier)
        try store.remove(event, span: .thisEvent, commit: true)
    }

    public func event(identifier: String) async throws -> CalendarEventRecord? {
        try await requireFullAccess()
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            throw AgentError.invalidToolCall("Calendar event identifier must not be empty.")
        }
        return store.event(withIdentifier: normalized).map(calendarEventRecord(from:))
    }

    private func requireFullAccess() async throws {
        let granted: Bool
        try requireHostUsageDescription(
            "NSCalendarsFullAccessUsageDescription",
            capability: "Calendar full access"
        )
        granted = try await store.requestFullAccessToEvents()
        guard granted else {
            throw AgentError.accessDenied("Calendar full access was denied.")
        }
    }

    private func requireWriteAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly, .authorized:
            return
        default:
            try requireHostUsageDescription(
                "NSCalendarsWriteOnlyAccessUsageDescription",
                capability: "Calendar write-only access"
            )
            let granted = try await store.requestWriteOnlyAccessToEvents()
            guard granted else {
                throw AgentError.accessDenied("Calendar write access was denied.")
            }
        }
    }


    private func existingEvent(identifier: String) throws -> EKEvent {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            throw AgentError.invalidToolCall("Calendar event identifier must not be empty.")
        }
        guard let event = store.event(withIdentifier: normalized) else {
            throw AgentError.notFound("Calendar event not found: \(normalized)")
        }
        return event
    }

    private func apply(_ draft: CalendarEventDraft, to event: EKEvent) {
        let normalized = draft.normalizedForStorage
        event.title = normalized.title
        event.startDate = normalized.startDate
        event.endDate = normalized.endDate
        event.location = normalized.location
        event.notes = normalized.notes
        event.isAllDay = normalized.isAllDay
    }

    private func calendarEventRecord(from event: EKEvent) -> CalendarEventRecord {
        CalendarEventRecord(
            identifier: event.eventIdentifier,
            title: event.title ?? "",
            startDate: event.startDate,
            endDate: event.endDate,
            location: event.location,
            notes: event.notes,
            isAllDay: event.isAllDay,
            revision: calendarEventRevision(from: event)
        )
    }

    private func calendarEventRevision(from event: EKEvent) -> String {
        let state = [
            event.eventIdentifier,
            event.title ?? "",
            String(event.startDate.timeIntervalSinceReferenceDate.bitPattern, radix: 16),
            String(event.endDate.timeIntervalSinceReferenceDate.bitPattern, radix: 16),
            event.location ?? "",
            event.notes ?? "",
            event.isAllDay ? "1" : "0"
        ].joined(separator: "\u{0}")
        return "eventkit:" + SHA256HexDigest.digest(state)
    }
}

#endif
