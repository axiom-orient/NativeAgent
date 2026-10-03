import ASKLatencyProbe
import Foundation

let arguments = ProcessInfo.processInfo.arguments

func fail(_ reason: String) -> Never {
    FileHandle.standardError.write(Data("[LatencyProbe] \(reason)\n".utf8))
    FileHandle.standardError.write(Data("""
    Usage: LatencyProbe --workspace <file:///absolute/path> [--documents N] [--size-kb K]
                        [--iterations S] [--output report.json]

    Generates a representative markdown corpus and measures import, search,
    and cold-relaunch replay latency through the public ASK facade.

    """.utf8))
    exit(2)
}

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

guard let workspaceArgument = value(after: "--workspace") else {
    fail("--workspace is required")
}
guard let workspaceURL = URL(string: workspaceArgument), workspaceURL.isFileURL,
      workspaceURL.path.hasPrefix("/")
else {
    fail("--workspace must be an absolute file:// URL")
}

var configuration = LatencyProbeRun.Configuration()
if let raw = value(after: "--documents"), let count = Int(raw), count > 0 { configuration.documentCount = count }
if let raw = value(after: "--size-kb"), let size = Int(raw), size > 0 { configuration.documentKilobytes = size }
if let raw = value(after: "--dm-seed"), let seeds = Int(raw), seeds >= 0 {
                configuration.decisionMemorySeedCount = seeds
            }
            if let raw = value(after: "--iterations"), let iterations = Int(raw), iterations > 0 {
    configuration.searchIterations = iterations
}

let probe = LatencyProbeRun(configuration: configuration)
do {
    let report = try await probe.run(workspaceURL: workspaceURL)
    let encoded = try JSONEncoder().encode(report)
    if let outputPath = value(after: "--output") {
        try Data(encoded).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        FileHandle.standardError.write(Data("[LatencyProbe] report written to \(outputPath)\n".utf8))
    }
    print(String(decoding: encoded, as: UTF8.self))
} catch {
    fail(String(describing: error))
}
