import ASK
import ASKFoundationModels
import Foundation
import SwiftUI

#if canImport(FoundationModels)
import FoundationModels

@main
struct ASKFMHarnessApp: App {
    @State private var runner = FMProbeRunner()

    var body: some Scene {
        WindowGroup {
            FMProbeRunnerView(runner: runner)
                .task { await runner.start() }
        }
    }
}

@MainActor
@Observable
final class FMProbeRunner {
    enum RunState {
        case idle
        case running
        case partial(String)
        case completed(String)
        case failed(String)
    }

    private(set) var state: RunState = .idle
    private(set) var reportFileURL: URL?

    func start() async {
        guard case .idle = state else { return }
        state = .running
        let report: String
        do {
            report = try await Self.probe()
        } catch {
            report = Self.failureReport(stage: "probe", error: error)
        }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documents.appendingPathComponent("ask-fm-report.json")
        do {
            try Data(report.utf8).write(to: fileURL, options: .atomic)
            reportFileURL = fileURL
        } catch {
            let failure = Self.failureReport(stage: "report_write", error: error)
            print("ASK_FM_REPORT_WRITE_FAILED: \(error)")
            state = .failed(failure)
            return
        }

        let object = try? JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any]
        switch object?["status"] as? String {
        case "failed": state = .failed(report)
        case "partial": state = .partial(report)
        default: state = .completed(report)
        }
    }

    /// Availability → direct tool-call smoke against a seeded workspace → one
    /// live model turn when the on-device model is usable. Every step lands in
    /// a single JSON report for pull-based verification.
    nonisolated static func probe() async throws -> String {
        var report: [String: Any] = ["status": "passed", "runID": UUID().uuidString, "createdAt": ISO8601DateFormatter().string(from: Date())]
        report["environment"] = executionEnvironment()

        var stage = "availability"
        do {
            let availability: ASKFoundationModelAvailability = ASKFoundationModelAvailability.current()
            report["availability"] = [
                "case": String(describing: availability),
                "usable": availability.isUsable,
                "message": availability.localizedDescription,
            ]

            stage = "workspace_setup"
            let workspace = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ASKFMProbe-" + UUID().uuidString, isDirectory: true)
            let suite = ASKFoundationModelsToolSuite(configuration: ASKConfiguration(workspaceURL: workspace))

            if !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("vault").path) {
                let sourceRoot = workspace.deletingLastPathComponent()
                    .appendingPathComponent("ask-fm-harness-sources", isDirectory: true)
                try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
                for index in 0..<5 {
                    let file = sourceRoot.appendingPathComponent("study-\(index).md")
                    try Data("""
                    # Study note \(index)

                    The spaced repetition checkpoint \(index) covers retention decay and
                    active recall scheduling for the quarterly review.
                    The review interval is \(7 + index * 4) days. This is a review interval, not a deadline.
                    """.utf8).write(to: file)
                }
                let client = ASKClient(configuration: ASKConfiguration(workspaceURL: workspace))
                let plan = try client.plan(.importWorkspace(ASKImportWorkspaceCommand(
                    sourceRootURL: sourceRoot,
                    title: "FM harness study notes",
                    queryText: "spaced repetition checkpoint",
                    requestedAt: "2026-08-24T00:00:00Z",
                    resetExistingWorkspace: true
                )))
                _ = try await client.apply(plan)
            }

            stage = "tool_smoke"
            guard let tool = suite.tools.compactMap({ $0 as? ASKEvidenceSearchTool }).first else {
                throw ASKFoundationModelsToolError.unexpectedResult(tool: ASKEvidenceSearchTool.toolName)
            }
            let arguments = try GeneratedContent(json: #"{"text":"spaced repetition","limit":1}"#)
            let started = Date()
            let output = try await tool.call(arguments: ASKEvidenceSearchTool.Arguments(arguments))
            guard output.contains("Study note"), output.contains("spaced repetition") else {
                throw ASKFoundationModelsToolError.unexpectedResult(tool: ASKEvidenceSearchTool.toolName)
            }
            report["toolSmoke"] = ["status": "passed", "tool": ASKEvidenceSearchTool.toolName,
                "milliseconds": Int(Date().timeIntervalSince(started) * 1000), "containsNote": true]

            if availability.isUsable {
                stage = "model_smoke"
                do {
                    let modelOnly = try await LanguageModelSession().respond(to: "Say ready in one word.")
                    guard !modelOnly.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ASKFoundationModelsToolError.unexpectedResult(tool: "model-only probe")
                    }
                    report["modelSmoke"] = ["status": "passed", "content": modelOnly.content]
                } catch {
                    recordFailure(&report, stage: stage, error: error)
                    report["modelSmoke"] = ["status": "failed", "error": errorDetails(error)]
                }
                stage = "live_session_setup"
                let session = try ASKFoundationModelsSessionFactory.makeSession(configuration: ASKConfiguration(workspaceURL: workspace))
                stage = "live_respond"
                do {
                    let response = try await session.respond(
                        to: "What review interval does Study note 0 specify? Give the exact value and unit, explain it briefly, and cite the note title."
                    )
                    let calledSearch = session.transcript.contains { entry in
                        if case .toolCalls(let calls) = entry { return calls.contains { $0.toolName == "search_evidence" } }
                        return false
                    }
                    let returnedNote = session.transcript.contains { entry in
                        guard case .toolOutput(let output) = entry, output.toolName == "search_evidence" else { return false }
                        return output.segments.contains { segment in
                            if case .text(let text) = segment { return text.content.contains("Study note 0") && text.content.contains("7 days") }
                            return false
                        }
                    }
                    guard calledSearch, returnedNote, !response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ASKFoundationModelsToolError.unexpectedResult(tool: "live grounded response")
                    }
                    // Tool invocation and a nonempty answer are transport proof.
                    // This seeded question has a separate exact-value/title oracle.
                    let answer = response.content
                    let correctValue = answer.range(of: #"(?i)\b(?:7|seven)\s+days?\b"#, options: .regularExpression) != nil
                    let citedTitle = answer.contains("Study note 0")
                    let noInventedLookup = !answer.contains("src_") && !answer.localizedCaseInsensitiveContains("couldn't find")
                    report["answerAccuracy"] = ["status": correctValue && citedTitle && noInventedLookup ? "passed" : "failed",
                        "exactValueAndUnit": correctValue, "citedExpectedTitle": citedTitle,
                        "noInventedLookupClaim": noInventedLookup,
                        "scope": "One curated interval question; not general semantic accuracy"]
                    report["liveRespond"] = ["status": "passed", "content": answer,
                        "actualSearchCall": calledSearch, "indexedNoteReturned": returnedNote]
                    guard correctValue, citedTitle, noInventedLookup else {
                        throw ASKFoundationModelsToolError.unexpectedResult(tool: "answer accuracy")
                    }
                } catch {
                    recordFailure(&report, stage: stage, error: error)
                    report["liveRespond"] = ["status": "failed", "error": errorDetails(error)]
                    report["liveRespondDiagnosis"] = liveRespondDiagnosis(for: error)
                }
                let toolCalls = session.transcript.flatMap { entry -> [String] in
                    if case .toolCalls(let calls) = entry { return calls.map(\.toolName) }
                    return []
                }
                report["toolCalls"] = toolCalls
                if toolCalls.isEmpty {
                    report["toolTranscriptInterpretation"] = "No tool-call entries were retained. After an error, the framework may roll the transcript back, so an empty array does not prove that no tool call was attempted."
                }
            } else {
                report["status"] = "partial"
                report["liveRespond"] = ["status": "not_run", "reason": availability.localizedDescription]
            }
        } catch {
            recordFailure(&report, stage: stage, error: error)
        }

        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func executionEnvironment() -> [String: Any] {
        var environment: [String: Any] = [
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "sdkName": Bundle.main.infoDictionary?["DTSDKName"] as? String ?? "unknown",
            "xcodeBuild": Bundle.main.infoDictionary?["DTXcodeBuild"] as? String ?? "unknown",
        ]
        #if targetEnvironment(simulator)
        environment["target"] = "iOS Simulator"
        environment["simulatorDevice"] = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "unknown"
        environment["hostOSVersion"] = "not exposed to the app process"
        #else
        environment["target"] = "physical device"
        #endif
        return environment
    }

    nonisolated private static func recordFailure(_ report: inout [String: Any], stage: String, error: Error) {
        report["status"] = "failed"
        var failures = report["failures"] as? [[String: Any]] ?? []
        failures.append(["stage": stage, "error": errorDetails(error)])
        report["failures"] = failures
    }

    nonisolated private static func errorDetails(_ error: Error, depth: Int = 0) -> [String: Any] {
        let nsError = error as NSError
        var details: [String: Any] = [
            "domain": nsError.domain,
            "code": nsError.code,
            "message": nsError.localizedDescription,
            "debugDescription": String(reflecting: error),
        ]
        if let suggestion = nsError.localizedRecoverySuggestion {
            details["recoverySuggestion"] = suggestion
        }
        guard depth < 8 else { return details }

        var underlying: [NSError] = []
        if let single = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            underlying.append(single)
        }
        if let multiple = nsError.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
            underlying.append(contentsOf: multiple)
        }
        if !underlying.isEmpty {
            details["underlyingErrors"] = underlying.map { errorDetails($0, depth: depth + 1) }
        }
        return details
    }

    nonisolated private static func liveRespondDiagnosis(for error: Error) -> [String: Any] {
        let assessment: String
        if error is ASKFoundationModelsToolError {
            assessment = "The model returned, but the response failed the probe's assertion that search_evidence was called and its indexed note was returned."
        } else {
            assessment = "The direct ASK search smoke passed, but the tool-enabled Foundation Models response failed. The underlying error is preserved without assigning undocumented private error codes a meaning."
        }
        return [
            "assessment": assessment,
            "simulatorGuidance": "On Simulator, verify that the host macOS, Xcode, and selected iOS Simulator runtime versions are aligned. The app cannot read the host macOS version.",
            "causeConfirmed": false,
            "reference": "https://developer.apple.com/forums/thread/787445",
        ]
    }

    nonisolated private static func failureReport(stage: String, error: Error) -> String {
        let report: [String: Any] = [
            "status": "failed",
            "runID": UUID().uuidString,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "environment": executionEnvironment(),
            "failures": [["stage": stage, "error": errorDetails(error)]],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return #"{"status":"failed","stage":"report_generation"}"#
    }
}

struct FMProbeRunnerView: View {
    @Bindable var runner: FMProbeRunner

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("ASK FM Probe")
                .toolbar {
                    if let url = runner.reportFileURL {
                        ShareLink(item: url, preview: SharePreview("ask-fm-report.json"))
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch runner.state {
        case .idle:
            Text("Ready")
        case .running:
            ProgressView("Probing on-device intelligence…")
        case .partial(let report):
            VStack(alignment: .leading, spacing: 12) {
                Label("Model probe incomplete", systemImage: "exclamationmark.circle")
                    .font(.title2)
                Text("The ASK tool smoke passed, but the live model response was not run because Foundation Models reported unavailable.")
                    .foregroundStyle(.secondary)
                reportText(report)
            }
            .padding()
        case .failed(let report):
            VStack(alignment: .leading, spacing: 12) {
                Label("Probe failed", systemImage: "xmark.octagon")
                    .font(.title2)
                Text(runner.reportFileURL == nil
                    ? "The report could not be saved; details are shown below."
                    : "The detailed failure report can be shared from the toolbar.")
                    .foregroundStyle(.secondary)
                reportText(report)
            }
            .padding()
        case .completed(let report):
            reportText(report)
        }
    }

    private func reportText(_ report: String) -> some View {
        ScrollView {
            Text(report)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding()
        }
    }
}
#endif
