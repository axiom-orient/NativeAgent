import Foundation
import KnowledgeCore

enum ASKCommandPlanner {
    static func validate(_ command: ASKCommand) throws {
        switch command {
        case .quickStart(let value):
            try validateTimestamp(value.requestedAt, field: "requestedAt")
            try validateNonempty(value.decidedBy, field: "decidedBy")
            try validateNonempty(value.reason, field: "reason")
        case .indexWorkspace(let value):
            try validateURL(value.sourceRootURL, field: "sourceRootURL")
        case .importWorkspace(let value):
            try validateURL(value.sourceRootURL, field: "sourceRootURL")
            try validateNonempty(value.title, field: "title")
            try validateNonempty(value.queryText, field: "queryText")
            try validateTimestamp(value.requestedAt, field: "requestedAt")
            try validatePositive(value.maxEvidenceBytes, field: "maxEvidenceBytes")
        case .stageReport(let value):
            try validateNonempty(value.title, field: "title")
            try validateNonempty(value.queryText, field: "queryText")
            try validateTimestamp(value.requestedAt, field: "requestedAt")
            try validatePositive(value.maxEvidenceBytes, field: "maxEvidenceBytes")
        case .closeDay(let value):
            try validateNonempty(value.date, field: "date")
            try validateTimestamp(value.requestedAt, field: "requestedAt")
            try validatePositive(value.maxEvidenceBytes, field: "maxEvidenceBytes")
        case .importCapture(let value):
            try validateURL(value.captureManifestURL, field: "captureManifestURL")
            try validateNonempty(value.domain, field: "domain")
            try validateTimestamp(value.requestedAt, field: "requestedAt")
        case .decidePatch(let value):
            try validateNonempty(value.patchID, field: "patchID")
            try validateNonempty(value.decidedBy, field: "decidedBy")
            try validateTimestamp(value.decidedAt, field: "decidedAt")
            try validateNonempty(value.reason, field: "reason")
        case .repairPresentation(let value):
            try ASKPresentationRepairTokenFactory.verify(value.token)
            try validateNonempty(value.token.id, field: "repairToken.id")
            try validateNonempty(value.token.actionID, field: "repairToken.actionID")
            try validateTimestamp(value.token.createdAt, field: "repairToken.createdAt")
            try validateTimestamp(value.requestedAt, field: "requestedAt")
            guard !value.token.projectionSlugs.isEmpty else {
                throw ASKDiagnostic(
                    code: .missingField,
                    operation: .plan,
                    message: "Missing required field: repairToken.projectionSlugs",
                    context: ["field": "repairToken.projectionSlugs"],
                    recovery: .correctInput
                )
            }
        case .rebuildKnowledge(let value):
            try validateTimestamp(value.requestedAt, field: "requestedAt")
        case .recordDecisionMemory(let value):
            try value.record.validate()
        case .recordDecisionMemories(let value):
            guard !value.records.isEmpty else {
                throw ASKError.validation("decision-memory batch must not be empty")
            }
            for record in value.records { try record.validate() }
        case .transitionDecisionMemory(let value):
            try value.transition.validate()
        case .consolidateDecisionMemory(let value):
            try validateTimestamp(value.asOf, field: "asOf")
        }
    }

    static func context(for command: ASKCommand, configuration: ASKConfiguration) -> ASKPlanContext {
        let selection = command.workspaceSelection
        return context(
            for: selection,
            configuration: configuration,
            sourceRootURL: command.sourceRootURL,
            captureManifestURL: command.captureManifestURL
        )
    }

    static func context(
        for selection: ASKWorkspaceSelection,
        configuration: ASKConfiguration,
        sourceRootURL: URL? = nil,
        captureManifestURL: URL? = nil
    ) -> ASKPlanContext {
        let workspaceURL = askCanonicalFileURL(selection.workspaceURL ?? configuration.workspaceURL)
        let usesWorkspaceOverride = selection.workspaceURL != nil
        let vaultURL = selection.vaultURL
            ?? (usesWorkspaceOverride
                ? workspaceURL.appendingPathComponent("vault", isDirectory: true)
                : configuration.resolvedVaultURL)
        let indexURL = selection.indexURL
            ?? (usesWorkspaceOverride
                ? workspaceURL.appendingPathComponent("index", isDirectory: true)
                : configuration.resolvedIndexURL)
        let productURL = selection.productWorkspaceURL
            ?? (usesWorkspaceOverride
                ? workspaceURL.appendingPathComponent("product", isDirectory: true)
                : configuration.resolvedProductWorkspaceURL)
        return ASKPlanContext(
            workspaceURL: workspaceURL,
            vaultURL: vaultURL,
            indexURL: indexURL,
            productWorkspaceURL: productURL,
            sourceRootURL: sourceRootURL,
            captureManifestURL: captureManifestURL
        )
    }

    static func makePlan(_ command: ASKCommand, configuration: ASKConfiguration) throws -> ASKCommandPlan {
        try validate(command)
        try validateFileRoutes(
            configuration: configuration,
            selection: command.workspaceSelection,
            sourceRootURL: command.sourceRootURL,
            captureManifestURL: command.captureManifestURL
        )
        let context = context(for: command, configuration: configuration)
        try validateManagedRoutes(command: command, context: context, configuration: configuration)
        return ASKCommandPlan(
            actionID: try actionID(for: command, context: context),
            command: command,
            context: context,
            summary: summary(for: command)
        )
    }

    static func actionID(for command: ASKCommand, context: ASKPlanContext) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let commandData = try encoder.encode(command)
        let contextData = try encoder.encode(context)
        let payload = commandData + Data([0x0A]) + contextData
        return "ask-\(ASKSHA256.hexDigest(payload).prefix(16))"
    }

    static func summary(for command: ASKCommand) -> String {
        switch command {
        case .quickStart:
            "Create a sample evidence workspace and apply a reviewed WorkWiki projection."
        case .indexWorkspace:
            "Index source files without staging or committing canonical knowledge."
        case .importWorkspace:
            "Index an existing source workspace and apply a reviewed WorkWiki projection."
        case .stageReport:
            "Build an evidence-backed WorkWiki report patch."
        case .closeDay:
            "Build a daily WorkWiki close-day patch."
        case .importCapture:
            "Import captured evidence and stage an ingest patch."
        case .decidePatch(let value):
            value.decision == .approved
                ? "Approve a pending WorkWiki patch."
                : "Reject a pending WorkWiki patch."
        case .repairPresentation:
            "Repair derived presentation output after a committed knowledge change."
        case .rebuildKnowledge:
            "Rebuild all derived knowledge artifacts from the canonical journal."
        case .recordDecisionMemory:
            "Append an immutable STIM decision-memory record."
        case .recordDecisionMemories:
            "Append immutable STIM decision-memory records in one journal pass."
        case .transitionDecisionMemory:
            "Append an immutable decision-memory lifecycle transition."
        case .consolidateDecisionMemory:
            "Rebuild generated decision-memory Markdown from canonical journal facts."
        }
    }

    private static func validateManagedRoutes(
        command: ASKCommand,
        context: ASKPlanContext,
        configuration: ASKConfiguration
    ) throws {
        switch command {
        case .indexWorkspace:
            guard isDescendant(context.indexURL, of: context.workspaceURL) else {
                throw ASKDiagnostic(
                    code: .invalidRequest,
                    operation: .plan,
                    message: "indexURL must be inside workspaceURL for source indexing",
                    context: [
                        "workspacePath": context.workspaceURL.path,
                        "path": context.indexURL.path,
                    ],
                    recovery: .correctInput
                )
            }
        case .quickStart, .importWorkspace:
            // Every managed route these workflows write to has to stay inside the
            // workspace. The product root was previously exempt even though repair
            // records and reading bundles are written under it.
            let managedRoutes = [
                ("indexURL", context.indexURL),
                ("vaultURL", context.vaultURL),
                ("productWorkspaceURL", context.productWorkspaceURL),
            ]
            for (field, url) in managedRoutes {
                guard isDescendant(url, of: context.workspaceURL) else {
                    throw ASKDiagnostic(
                        code: .invalidRequest,
                        operation: .plan,
                        message: "\(field) must be inside workspaceURL for workspace creation workflows",
                        context: [
                            "field": field,
                            "workspacePath": context.workspaceURL.path,
                            "path": url.path,
                        ],
                        recovery: .correctInput
                    )
                }
            }
        case .repairPresentation(let value):
            let configuredRoutes = [
                ("knowledgeRootURL", value.token.knowledgeRootURL, configuration.resolvedVaultURL),
                ("productWorkspaceURL", value.token.productWorkspaceURL, configuration.resolvedProductWorkspaceURL),
            ]
            for (field, route, configuredRoute) in configuredRoutes {
                guard isSameOrDescendant(route, of: context.workspaceURL)
                    || askCanonicalFileURL(route).path == askCanonicalFileURL(configuredRoute).path
                else {
                    throw ASKDiagnostic(
                        code: .invalidRequest,
                        operation: .plan,
                        message: "\(field) must be inside workspaceURL or equal its configured route for presentation repair",
                        context: [
                            "field": field,
                            "workspacePath": context.workspaceURL.path,
                            "configuredPath": configuredRoute.path,
                            "path": route.path,
                        ],
                        recovery: .correctInput
                    )
                }
            }
        case .stageReport, .closeDay, .importCapture, .decidePatch, .rebuildKnowledge,
             .recordDecisionMemory, .recordDecisionMemories, .transitionDecisionMemory, .consolidateDecisionMemory:
            break
        }
    }

    /// Lexical containment. Planning is contractually free of I/O, so this cannot resolve
    /// symlinks; `ASKManagedRouteContainment` re-checks the same routes at the effect
    /// boundary, where touching the filesystem is legitimate.
    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let childPath = askCanonicalFileURL(child).path
        let parentPath = askCanonicalFileURL(parent).path
        return childPath.hasPrefix(parentPath + "/")
    }

    private static func isSameOrDescendant(_ child: URL, of parent: URL) -> Bool {
        let childPath = askCanonicalFileURL(child).path
        let parentPath = askCanonicalFileURL(parent).path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    private static func validateNonempty(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASKDiagnostic(
                code: .missingField,
                operation: .plan,
                message: "Missing required field: \(field)",
                context: ["field": field],
                recovery: .correctInput
            )
        }
    }

    /// Timestamp acceptance is the domain's, not the facade's. A second validator here
    /// drifted from `ASKTimestamp` and rejected fractional seconds that the core accepts.
    private static func validateTimestamp(_ value: String, field: String) throws {
        try validateNonempty(value, field: field)
        guard ASKTimestamp.isValidRFC3339(value) else {
            throw ASKDiagnostic(
                code: .invalidRequest,
                operation: .plan,
                message: "\(field) must be an RFC3339 timestamp",
                context: ["field": field, "value": value],
                recovery: .correctInput
            )
        }
    }

    private static func validatePositive(_ value: Int, field: String) throws {
        guard value > 0 else {
            throw ASKDiagnostic(
                code: .invalidRequest,
                operation: .plan,
                message: "\(field) must be positive",
                context: ["field": field, "value": String(value)],
                recovery: .correctInput
            )
        }
    }

    static func validateFileRoutes(
        configuration: ASKConfiguration,
        selection: ASKWorkspaceSelection,
        sourceRootURL: URL? = nil,
        captureManifestURL: URL? = nil
    ) throws {
        try validateFileURL(configuration.workspaceURL, field: "configuration.workspaceURL")
        if let url = configuration.vaultURL {
            try validateFileURL(url, field: "configuration.vaultURL")
        }
        if let url = configuration.indexURL {
            try validateFileURL(url, field: "configuration.indexURL")
        }
        if let url = configuration.productWorkspaceURL {
            try validateFileURL(url, field: "configuration.productWorkspaceURL")
        }

        if let url = selection.workspaceURL {
            try validateFileURL(url, field: "workspace.workspaceURL")
        }
        if let url = selection.vaultURL {
            try validateFileURL(url, field: "workspace.vaultURL")
        }
        if let url = selection.indexURL {
            try validateFileURL(url, field: "workspace.indexURL")
        }
        if let url = selection.productWorkspaceURL {
            try validateFileURL(url, field: "workspace.productWorkspaceURL")
        }
        if let url = sourceRootURL {
            try validateFileURL(url, field: "sourceRootURL")
        }
        if let url = captureManifestURL {
            try validateFileURL(url, field: "captureManifestURL")
        }
    }

    private static func validateURL(_ value: URL, field: String) throws {
        try validateFileURL(value, field: field)
    }

    private static func validateFileURL(_ value: URL, field: String) throws {
        guard value.isFileURL else {
            throw ASKDiagnostic(
                code: .invalidRequest,
                operation: .plan,
                message: "\(field) must be a file URL",
                context: ["field": field, "url": value.absoluteString],
                recovery: .correctInput
            )
        }
        guard !value.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASKDiagnostic(
                code: .missingField,
                operation: .plan,
                message: "Missing required field: \(field)",
                context: ["field": field],
                recovery: .correctInput
            )
        }
    }
}

enum ASKCommandPlanIntegrity {
    static func verify(_ plan: ASKCommandPlan, configuration: ASKConfiguration) throws {
        let expected = try ASKCommandPlanner.makePlan(plan.command, configuration: configuration)
        guard plan == expected else {
            throw ASKDiagnostic(
                code: .integrityViolation,
                operation: .apply,
                message: "Command plan integrity mismatch",
                context: ["actionID": plan.actionID],
                recovery: .correctInput
            )
        }
    }
}

extension ASKCommand {
    var workspaceSelection: ASKWorkspaceSelection {
        switch self {
        case .quickStart(let value): value.workspace
        case .indexWorkspace(let value): value.workspace
        case .importWorkspace(let value): value.workspace
        case .stageReport(let value): value.workspace
        case .closeDay(let value): value.workspace
        case .importCapture(let value): value.workspace
        case .decidePatch(let value): value.workspace
        case .repairPresentation(let value):
            ASKWorkspaceSelection(
                vaultURL: value.token.knowledgeRootURL,
                productWorkspaceURL: value.token.productWorkspaceURL
            )
        case .rebuildKnowledge(let value): value.workspace
        case .recordDecisionMemory(let value): value.workspace
        case .recordDecisionMemories(let value): value.workspace
        case .transitionDecisionMemory(let value): value.workspace
        case .consolidateDecisionMemory(let value): value.workspace
        }
    }

    var sourceRootURL: URL? {
        switch self {
        case .indexWorkspace(let value): value.sourceRootURL
        case .importWorkspace(let value): value.sourceRootURL
        default: nil
        }
    }

    var captureManifestURL: URL? {
        guard case .importCapture(let value) = self else { return nil }
        return value.captureManifestURL
    }
}

extension ASKQuery {
    var workspaceSelection: ASKWorkspaceSelection {
        switch self {
        case .groundedEvidence(let value): value.workspace
        case .resolveEvidence(let value): value.workspace
        case .searchEvidence(let value): value.workspace
        case .searchKnowledge(let value): value.workspace
        case .retrieveEvidence(let value): value.workspace
        case .projection(let value): value.workspace
        case .markdownPage: ASKWorkspaceSelection()
        case .readingContext(let value): value.workspace
        case .storageHealth(let value): value.workspace
        case .pendingWork(let value): value.workspace
        case .sourceInspect(let value): value.workspace
        case .pendingPatch(let value): value.workspace
        case .decisionMemory(let value): value.workspace
        }
    }
}
