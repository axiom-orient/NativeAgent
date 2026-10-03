import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentTools

private actor RecordingCalendarService: CalendarToolService {
    private let listResultCount: Int
    private(set) var listed: (Date, Date, Int, String?)?
    private(set) var created: CalendarEventDraft?
    private(set) var updated: (String, CalendarEventDraft)?
    private(set) var deleted: String?

    init(listResultCount: Int = 1) {
        self.listResultCount = listResultCount
    }

    func listEvents(
        startDate: Date,
        endDate: Date,
        limit: Int,
        cursor: String?
    ) async throws -> CalendarEventPage {
        listed = (startDate, endDate, limit, cursor)
        return CalendarEventPage(events: (0..<listResultCount).map { index in
            CalendarEventRecord(
                identifier: "event-\(index)",
                title: "All day",
                startDate: startDate,
                endDate: endDate,
                isAllDay: true
            )
        }, nextCursor: listResultCount > 0 ? "next" : nil)
    }

    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEventRecord {
        created = draft
        return record(identifier: "created", draft: draft)
    }

    func updateEvent(identifier: String, draft: CalendarEventDraft) async throws -> CalendarEventRecord {
        updated = (identifier, draft)
        return record(identifier: identifier, draft: draft)
    }

    func deleteEvent(identifier: String) async throws {
        deleted = identifier
    }

    private func record(identifier: String, draft: CalendarEventDraft) -> CalendarEventRecord {
        CalendarEventRecord(
            identifier: identifier,
            title: draft.title,
            startDate: draft.startDate,
            endDate: draft.endDate,
            location: draft.location,
            notes: draft.notes,
            isAllDay: draft.isAllDay
        )
    }
}


private actor VerifyingCalendarService: CalendarToolService, CalendarEventVerificationService {
    private var stored: CalendarEventRecord?
    private var revisionCounter: Int = 1

    init(event: CalendarEventRecord) {
        self.stored = event
    }

    func listEvents(
        startDate: Date,
        endDate: Date,
        limit: Int,
        cursor: String?
    ) async throws -> CalendarEventPage {
        CalendarEventPage(events: stored.map { [$0] } ?? [], nextCursor: nil)
    }

    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEventRecord {
        revisionCounter += 1
        let record = makeRecord(identifier: "created", draft: draft)
        stored = record
        return record
    }

    func updateEvent(identifier: String, draft: CalendarEventDraft) async throws -> CalendarEventRecord {
        revisionCounter += 1
        let record = makeRecord(identifier: identifier, draft: draft)
        stored = record
        return record
    }

    func deleteEvent(identifier: String) async throws {
        guard stored?.identifier == identifier else {
            throw AgentError.notFound("Calendar event not found: \(identifier)")
        }
        stored = nil
    }

    func event(identifier: String) async throws -> CalendarEventRecord? {
        guard stored?.identifier == identifier else { return nil }
        return stored
    }

    private func makeRecord(identifier: String, draft: CalendarEventDraft) -> CalendarEventRecord {
        CalendarEventRecord(
            identifier: identifier,
            title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            startDate: draft.startDate,
            endDate: draft.endDate,
            location: draft.location,
            notes: draft.notes,
            isAllDay: draft.isAllDay,
            revision: "rev-\(revisionCounter)"
        )
    }
}

@Test
func calendarToolPackSupportsCompleteCRUDAndAllDayEvents() async throws {
    let service = RecordingCalendarService()
    let pack = CalendarToolPack(service: service)
    let executors = Dictionary(uniqueKeysWithValues: pack.executors().map { ($0.definition.name, $0) })

    #expect(Set(executors.keys) == [
        "calendar.listEvents",
        "calendar.createEvent",
        "calendar.updateEvent",
        "calendar.deleteEvent",
    ])
    #expect(executors["calendar.listEvents"]?.definition.approvalPolicy == .requireApproval)
    #expect(executors["calendar.createEvent"]?.definition.approvalPolicy == .requireApproval)
    #expect(executors.values.allSatisfy {
        $0.definition.metadata["sensitiveData"]?.boolValue == true
    })

    let arguments: JSONValue = [
        "title": "Trip",
        "startDate": "2026-07-29T00:00:00Z",
        "endDate": "2026-07-31T00:00:00Z",
        "isAllDay": true,
    ]
    let context = noopContext(root: FileManager.default.temporaryDirectory)
    let listed = try await #require(executors["calendar.listEvents"]).execute(
        call: ToolCall(
            name: "calendar.listEvents",
            arguments: [
                "startDate": "2026-07-01T00:00:00Z",
                "endDate": "2026-08-01T00:00:00Z",
                "limit": 10,
            ]
        ),
        context: context
    )
    #expect(listed.metadata["resultCount"] == .integer(1))
    #expect(await service.listed?.2 == 10)

    let created = try await #require(executors["calendar.createEvent"]).execute(
        call: ToolCall(name: "calendar.createEvent", arguments: arguments),
        context: context
    )
    #expect(created.output.objectValue?["identifier"]?.stringValue == "created")
    #expect(created.output.objectValue?["isAllDay"]?.boolValue == true)
    #expect(await service.created?.isAllDay == true)

    var updateObject = try #require(arguments.objectValue)
    updateObject["identifier"] = "event-1"
    let updated = try await #require(executors["calendar.updateEvent"]).execute(
        call: ToolCall(name: "calendar.updateEvent", arguments: .object(updateObject)),
        context: context
    )
    #expect(updated.output.objectValue?["identifier"]?.stringValue == "event-1")
    #expect(await service.updated?.0 == "event-1")

    _ = try await #require(executors["calendar.deleteEvent"]).execute(
        call: ToolCall(name: "calendar.deleteEvent", arguments: ["identifier": "event-1"]),
        context: context
    )
    #expect(await service.deleted == "event-1")
}

@Test
func calendarListSupportsLongRangesAndRejectsProviderOverflow() async throws {
    let context = noopContext(root: FileManager.default.temporaryDirectory)
    let rangeService = RecordingCalendarService()
    let rangeExecutor = try #require(
        CalendarToolPack(service: rangeService).executors().first {
            $0.definition.name == "calendar.listEvents"
        }
    )
    let longRange = try await rangeExecutor.execute(
        call: ToolCall(
            name: "calendar.listEvents",
            arguments: [
                "startDate": "2020-01-01T00:00:00Z",
                "endDate": "2030-01-03T00:00:00Z",
                "limit": 10,
            ]
        ),
        context: context
    )
    #expect(await rangeService.listed != nil)
    #expect(longRange.output.objectValue?["nextCursor"]?.stringValue == "next")
    #expect(longRange.output.objectValue?["hasMore"]?.boolValue == true)

    _ = try await rangeExecutor.execute(
        call: ToolCall(
            name: "calendar.listEvents",
            arguments: [
                "startDate": "2020-01-01T00:00:00Z",
                "endDate": "2030-01-03T00:00:00Z",
                "cursor": "next",
            ]
        ),
        context: context
    )
    #expect(await rangeService.listed?.3 == "next")

    let overflowService = RecordingCalendarService(listResultCount: 2)
    let overflowExecutor = try #require(
        CalendarToolPack(service: overflowService).executors().first {
            $0.definition.name == "calendar.listEvents"
        }
    )
    await #expect(throws: AgentError.self) {
        _ = try await overflowExecutor.execute(
            call: ToolCall(
                name: "calendar.listEvents",
                arguments: [
                    "startDate": "2026-01-01T00:00:00Z",
                    "endDate": "2026-01-02T00:00:00Z",
                    "limit": 1,
                ]
            ),
            context: context
        )
    }
}

@Test
func calendarToolPackRejectsMalformedAllDayFlagBeforeEffects() async throws {
    let service = RecordingCalendarService()
    let executor = try #require(
        CalendarToolPack(service: service).executors().first {
            $0.definition.name == "calendar.createEvent"
        }
    )

    await #expect(throws: ToolPreflightFailure.self) {
        _ = try await executor.execute(
            call: ToolCall(
                name: "calendar.createEvent",
                arguments: [
                    "title": "Bad",
                    "startDate": "2026-07-29T00:00:00Z",
                    "endDate": "2026-07-30T00:00:00Z",
                    "isAllDay": "yes",
                ]
            ),
            context: noopContext(root: FileManager.default.temporaryDirectory)
        )
    }
    #expect(await service.created == nil)
}

@Test
func calendarListRejectsWrongPageSizeTypeBeforeService() async throws {
    let service = RecordingCalendarService()
    let executor = try #require(
        CalendarToolPack(service: service).executors().first {
            $0.definition.name == "calendar.listEvents"
        }
    )
    await #expect(throws: AgentError.self) {
        _ = try await executor.execute(
            call: ToolCall(
                name: "calendar.listEvents",
                arguments: [
                    "startDate": "2026-01-01T00:00:00Z",
                    "endDate": "2026-01-02T00:00:00Z",
                    "limit": "10",
                ]
            ),
            context: noopContext(root: FileManager.default.temporaryDirectory)
        )
    }
    #expect(await service.listed == nil)
}


@Test
func calendarMutationUsesRevisionPreconditionAndReadBackWhenAvailable() async throws {
    let formatter = ISO8601DateFormatter()
    let start = try #require(formatter.date(from: "2026-09-10T01:00:00Z"))
    let end = try #require(formatter.date(from: "2026-09-10T02:00:00Z"))
    let initial = CalendarEventRecord(
        identifier: "event-verify",
        title: "Before",
        startDate: start,
        endDate: end,
        isAllDay: false,
        revision: "rev-1"
    )
    let service = VerifyingCalendarService(event: initial)
    let executors = Dictionary(
        uniqueKeysWithValues: CalendarToolPack(service: service).executors().map {
            ($0.definition.name, $0)
        }
    )
    let context = noopContext(root: FileManager.default.temporaryDirectory)

    let staleArguments: JSONValue = [
        "identifier": "event-verify",
        "expectedRevision": "stale",
        "title": "After",
        "startDate": "2026-09-10T01:00:00Z",
        "endDate": "2026-09-10T02:00:00Z",
        "isAllDay": false
    ]
    await #expect(throws: ToolPreflightFailure.self) {
        _ = try await #require(executors["calendar.updateEvent"]).execute(
            call: ToolCall(name: "calendar.updateEvent", arguments: staleArguments),
            context: context
        )
    }
    #expect(try await service.event(identifier: "event-verify")?.title == "Before")

    var updateObject = try #require(staleArguments.objectValue)
    updateObject["expectedRevision"] = .string("rev-1")
    let updated = try await #require(executors["calendar.updateEvent"]).execute(
        call: ToolCall(name: "calendar.updateEvent", arguments: .object(updateObject)),
        context: context
    )
    #expect(updated.metadata["verification"]?.stringValue == "read_back")
    #expect(updated.output.objectValue?["title"]?.stringValue == "After")
    let revision = try #require(updated.output.objectValue?["revision"]?.stringValue)
    #expect(revision == "rev-2")

    let deleted = try await #require(executors["calendar.deleteEvent"]).execute(
        call: ToolCall(
            name: "calendar.deleteEvent",
            arguments: [
                "identifier": "event-verify",
                "expectedRevision": .string(revision)
            ]
        ),
        context: context
    )
    #expect(deleted.metadata["verification"]?.stringValue == "read_back")
    #expect(deleted.output.objectValue?["verifiedAbsent"]?.boolValue == true)
    #expect(try await service.event(identifier: "event-verify") == nil)
}
