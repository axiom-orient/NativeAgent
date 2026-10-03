import Foundation
import Testing
@testable import NativeAgentDomain
@testable import NativeAgentTools

@Test
func adapterDrivenAppleToolPacks() async throws {
    struct CalendarService: CalendarToolService {
        func listEvents(startDate: Date, endDate: Date, limit: Int, cursor: String?) async throws -> CalendarEventPage {
            CalendarEventPage(events: [CalendarEventRecord(identifier: "1", title: "Meeting", startDate: startDate, endDate: endDate)])
        }

        func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEventRecord {
            CalendarEventRecord(identifier: "2", title: draft.title, startDate: draft.startDate, endDate: draft.endDate)
        }

        func updateEvent(identifier: String, draft: CalendarEventDraft) async throws -> CalendarEventRecord {
            CalendarEventRecord(
                identifier: identifier,
                title: draft.title,
                startDate: draft.startDate,
                endDate: draft.endDate
            )
        }

        func deleteEvent(identifier: String) async throws {}
    }

    struct ContactsService: ContactsToolService {
        func search(query: String, limit: Int, cursor: String?) async throws -> ContactsPage {
            ContactsPage(contacts: [ContactRecord(identifier: "1", givenName: "Taylor", familyName: "Lee")])
        }
    }

    struct IntentsService: AppIntentsToolService {
        func toolDefinitions() -> [ToolDefinition] {
            [
                ToolDefinition(
                    name: "intent.echo",
                    description: "Echo text.",
                    capabilityID: .appIntents,
                    inputSchema: ToolSchema.object(
                        properties: ["text": ToolSchema.string()],
                        required: ["text"]
                    ),
                    approvalPolicy: .requireApproval
                )
            ]
        }

        func executeIntent(named: String, arguments: JSONValue) async throws -> ToolResult {
            .text(callID: "c1", toolName: named, content: try arguments.stringField("text"))
        }
    }

    let calendarPack = CalendarToolPack(service: CalendarService())
    #expect(calendarPack.executors().count == 4)

    let contactsPack = ContactsToolPack(service: ContactsService())
    #expect(contactsPack.executors().count == 1)
    #expect(contactsPack.executors().allSatisfy {
        $0.definition.metadata["sensitiveData"]?.boolValue == true
    })
    let contactsResult = try await contactsPack.executors()[0].execute(
        call: ToolCall(name: "contacts.search", arguments: ["query": "Taylor", "limit": 50]),
        context: noopContext(root: FileManager.default.temporaryDirectory)
    )
    let contacts = try #require(contactsResult.output.objectValue?["contacts"]?.arrayValue)
    #expect(contacts.count == 1)

    let appIntentsPack = AppIntentsToolPack(service: IntentsService())
    let result = try await appIntentsPack.executors()[0].execute(
        call: ToolCall(name: "intent.echo", arguments: ["text": "hi"]),
        context: noopContext(root: FileManager.default.temporaryDirectory)
    )
    #expect(result.renderedContent == "hi")

    let calendarExecutors = Dictionary(uniqueKeysWithValues: calendarPack.executors().map { ($0.definition.name, $0) })
    await #expect(throws: ToolPreflightFailure.self) {
        _ = try await calendarExecutors["calendar.createEvent"]!.execute(
            call: ToolCall(
                name: "calendar.createEvent",
                arguments: [
                    "title": "Backwards",
                    "startDate": "2026-04-09T10:00:00Z",
                    "endDate": "2026-04-09T09:00:00Z"
                ]
            ),
            context: noopContext(root: FileManager.default.temporaryDirectory)
        )
    }
}

@Test
func contactsToolPackRejectsProviderOverflowInsteadOfTruncating() async throws {
    struct OverflowingContactsService: ContactsToolService {
        func search(query: String, limit: Int, cursor: String?) async throws -> ContactsPage {
            ContactsPage(contacts: [
                ContactRecord(identifier: "1", givenName: "Taylor", familyName: "Lee"),
                ContactRecord(identifier: "2", givenName: "Taylor", familyName: "Kim"),
            ])
        }
    }

    let executor = try #require(ContactsToolPack(service: OverflowingContactsService()).executors().first)
    await #expect(throws: AgentError.self) {
        _ = try await executor.execute(
            call: ToolCall(
                name: "contacts.search",
                arguments: ["query": "Taylor", "limit": 1]
            ),
            context: noopContext(root: FileManager.default.temporaryDirectory)
        )
    }
}

@Test
func contactsToolPackSurfacesCursorAndRejectsOutOfRangePageSize() async throws {
    struct PagedContactsService: ContactsToolService {
        func search(query: String, limit: Int, cursor: String?) async throws -> ContactsPage {
            ContactsPage(
                contacts: [ContactRecord(identifier: "1", givenName: "Taylor", familyName: "Lee")],
                nextCursor: "contacts-page-2"
            )
        }
    }

    let executor = try #require(ContactsToolPack(service: PagedContactsService()).executors().first)
    let result = try await executor.execute(
        call: ToolCall(name: "contacts.search", arguments: ["query": "Taylor"]),
        context: noopContext(root: FileManager.default.temporaryDirectory)
    )
    #expect(result.output.objectValue?["nextCursor"]?.stringValue == "contacts-page-2")
    #expect(result.output.objectValue?["hasMore"]?.boolValue == true)

    await #expect(throws: AgentError.self) {
        _ = try await executor.execute(
            call: ToolCall(name: "contacts.search", arguments: ["query": "Taylor", "limit": 51]),
            context: noopContext(root: FileManager.default.temporaryDirectory)
        )
    }
}


@Test
func appIntentsToolPackPrefersContextAwareServiceWhenAvailable() async throws {
    struct ContextService: ContextAwareAppIntentsToolService {
        func toolDefinitions() -> [ToolDefinition] {
            [
                ToolDefinition(
                    name: "intent.sessionEcho",
                    description: "Echo the session identifier.",
                    capabilityID: .appIntents,
                    inputSchema: ToolSchema.object(properties: [:]),
                    approvalPolicy: .automatic
                )
            ]
        }

        func executeIntent(named: String, arguments: JSONValue) async throws -> ToolResult {
            .text(callID: "fallback", toolName: named, content: "fallback")
        }

        func executeIntent(named: String, arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
            .text(callID: "context", toolName: named, content: context.sessionID)
        }
    }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let context = noopContext(root: root)
    let pack = AppIntentsToolPack(service: ContextService())
    let executor = try #require(pack.executors().first { $0.definition.name == "intent.sessionEcho" })

    let result = try await executor.execute(
        call: ToolCall(id: "call-ctx", name: "intent.sessionEcho", arguments: .object([:])),
        context: context
    )

    #expect(result.renderedContent == "session")
    #expect(result.callID == "call-ctx")
}
