import ASK
import ASKLatencyProbe
import SwiftUI

@main
struct ASKLatencyHarnessApp: App {
    @State private var runner = ProbeRunner()

    var body: some Scene {
        WindowGroup {
            ProbeRunnerView(runner: runner)
        }
    }
}

@MainActor
@Observable
final class ProbeRunner {
    enum RunState {
        case idle
        case preparing
        case measuring
        case completed(LatencyProbeRun.Report)
        case failed(String)
    }

    private(set) var state: RunState = .idle
    private(set) var reportText = ""
    private(set) var reportFileURL: URL?

    nonisolated static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func start() async {
        guard case .idle = state else { return }
        state = .preparing
        do {
            let workspaceURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ASKProbe", isDirectory: true)
            var configuration = LatencyProbeRun.Configuration()
            configuration.searchIterations = 15
            // Launch-argument overrides (devicectl passes positional args):
            // --documents N --size-kb K --iterations S
            let arguments = ProcessInfo.processInfo.arguments
            func value(after flag: String) -> Int? {
                guard let index = arguments.firstIndex(of: flag),
                      arguments.indices.contains(index + 1),
                      let parsed = Int(arguments[index + 1]), parsed > 0
                else { return nil }
                return parsed
            }
            if let count = value(after: "--documents") { configuration.documentCount = count }
            if let size = value(after: "--size-kb") { configuration.documentKilobytes = size }
            if let iterations = value(after: "--iterations") { configuration.searchIterations = iterations }

            let probe = LatencyProbeRun(configuration: configuration)
            state = .measuring
            let report = try await probe.run(workspaceURL: workspaceURL)

            let encoded = try JSONEncoder().encode(report)
            let fileURL = Self.documentsDirectory().appendingPathComponent("ask-latency-report.json")
            try Data(encoded).write(to: fileURL, options: .atomic)
            if let pretty = (try? JSONSerialization.jsonObject(with: encoded))
                .flatMap({ try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys]) })
            {
                reportText = String(decoding: pretty, as: UTF8.self)
            }
            reportFileURL = fileURL
            state = .completed(report)
        } catch {
            state = .failed(String(describing: error))
        }
    }
}

struct ProbeRunnerView: View {
    @Bindable var runner: ProbeRunner

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("ASK Latency")
                .task { await runner.start() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch runner.state {
        case .idle:
            Text("Ready")
        case .preparing:
            ProgressView("Preparing corpus…")
        case .measuring:
            VStack(spacing: 12) {
                ProgressView()
                Text("Measuring import / search / replay…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            ContentUnavailableView("Probe failed", systemImage: "xmark.octagon", description: Text(message))
        case .completed(let report):
            List {
                Section("Summary") {
                    LabeledContent("Platform", value: report.platform)
                    LabeledContent("Corpus", value: "\(report.documentCount) docs × \(report.documentKilobytes) KB")
                    LabeledContent("Indexed", value: "\(report.indexedCount)")
                    LabeledContent("Total", value: String(format: "%.2fs", report.totalSeconds))
                }
                Section("Phases") {
                    ForEach(Array(report.phases.enumerated()), id: \.offset) { _, phase in
                        LabeledContent(phase.phase, value: String(format: "%.3fs", phase.seconds))
                    }
                }
                Section("Search samples") {
                    ForEach(Array(report.searches.enumerated()), id: \.offset) { _, sample in
                        VStack(alignment: .leading) {
                            Text(sample.query).font(.headline)
                            Text(String(format: "p50 %.0fms · p95 %.0fms · hits %d", sample.p50Seconds * 1_000, sample.p95Seconds * 1_000, sample.hitCount))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    if let url = runner.reportFileURL {
                        ShareLink(item: url, preview: SharePreview("ask-latency-report.json"))
                        LabeledContent("Report file", value: url.lastPathComponent)
                    }
                }
            }
        }
    }
}
