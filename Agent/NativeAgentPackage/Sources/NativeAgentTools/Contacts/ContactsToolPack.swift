import Foundation
import NativeAgentDomain

public struct ContactsToolPack: ToolPack {
    public let packID = "toolpack.contacts"
    private let service: any ContactsToolService

    public init(service: any ContactsToolService) {
        self.service = service
    }

    public func executors() -> [any ToolExecutor] {
        [
            ClosureToolExecutor(definition: searchDefinition) { call, _ in
                let request = try ContactsSearchRequest(arguments: call.arguments)
                let page = try await service.search(
                    query: request.query,
                    limit: request.limit,
                    cursor: request.cursor
                )
                guard page.contacts.count <= request.limit else {
                    throw AgentError.invariantViolation(
                        "Contacts provider returned more results than requested."
                    )
                }
                if let nextCursor = page.nextCursor {
                    guard nextCursor.isEmpty == false,
                          nextCursor.utf8.count <= ContactsSearchRequest.maximumCursorBytes else {
                        throw AgentError.invariantViolation("Contacts provider returned an invalid cursor.")
                    }
                }

                return ToolResult(
                    callID: call.id,
                    toolName: call.name,
                    output: contactsOutput(page)
                )
            }
        ]
    }

    private var searchDefinition: ToolDefinition {
        ToolDefinition(
            name: "contacts.search",
            description: "Search contacts by name, email, or phone number in bounded pages. Pass nextCursor with the same query to continue.",
            capabilityID: .contacts,
            inputSchema: ToolSchema.object(
                properties: [
                    "query": ToolSchema.string(description: "Contact search query.", minLength: 1),
                    "limit": ToolSchema.integer(description: "Maximum contacts in this page. Defaults to 10.", minimum: 1, maximum: ContactsSearchRequest.maximumPageSize),
                    "cursor": ToolSchema.string(description: "Opaque nextCursor from the preceding page for the same query.", minLength: 1, maxLength: ContactsSearchRequest.maximumCursorBytes)
                ],
                required: ["query"]
            ),
            approvalPolicy: .requireApproval,
            effect: .readOnly,
            metadata: ["sensitiveData": .bool(true)]
        )
    }
}
