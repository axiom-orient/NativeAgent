import Foundation
import NativeAgentDomain

func calendarEventsOutput(_ page: CalendarEventPage) -> JSONValue {
    .object([
        "events": .array(page.events.map(calendarEventObject(_:))),
        "nextCursor": page.nextCursor.map(JSONValue.string) ?? .null,
        "hasMore": .bool(page.nextCursor != nil)
    ])
}

func calendarEventOutput(_ event: CalendarEventRecord) -> JSONValue {
    calendarEventObject(event)
}

private func calendarEventObject(_ event: CalendarEventRecord) -> JSONValue {
    .object([
        "identifier": .string(event.identifier),
        "title": .string(event.title),
        "startDate": .string(nativeAgentISO8601String(from: event.startDate)),
        "endDate": .string(nativeAgentISO8601String(from: event.endDate)),
        "location": event.location.map(JSONValue.string) ?? .null,
        "notes": event.notes.map(JSONValue.string) ?? .null,
        "isAllDay": .bool(event.isAllDay),
        "revision": event.revision.map(JSONValue.string) ?? .null
    ])
}
