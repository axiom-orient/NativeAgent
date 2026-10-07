import Foundation
import SwiftUI

@main struct LiteRTUnifiedProbeApp: App {
  var body: some Scene { WindowGroup { ProbeView() } }
}

struct ProbeView: View {
  @State private var result = "Running native text and embedding qualification…"
  var body: some View {
    ScrollView { Text(result).font(.system(.caption, design: .monospaced)).padding() }
      .task {
        do {
          guard let text = Bundle.main.url(forResource: "text-qwen3-06b", withExtension: "litertlm"),
            let embedding = Bundle.main.url(forResource: "embeddinggemma-2-text-270m", withExtension: "litertlm")
          else { throw NSError(domain: "LiteRTQualification", code: 2) }
          let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
          let cpu = try await LiteRTUnifiedQualification.run(textURL: text, embeddingURL: embedding, cache: cache)
          let gpu = try await LiteRTUnifiedQualification.run(textURL: text, embeddingURL: embedding, cache: cache, backend: .gpu)
          let report = [cpu, gpu]
          let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          let data = try encoder.encode(report)
          try data.write(to: cache.appendingPathComponent("litert-unified-report.json"), options: .atomic)
          result = String(decoding: data, as: UTF8.self)
          print("LITERT_UNIFIED_REPORT " + result)
        } catch {
          result = "FAIL: \(error)"
          print("LITERT_UNIFIED_FAILURE \(error)")
        }
      }
  }
}
