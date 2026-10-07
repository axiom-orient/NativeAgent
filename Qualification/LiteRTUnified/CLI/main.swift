import Foundation
import LiteRTUnifiedQualification
import LiteRTProvider
@main struct Main {
  static func main() async throws {
    guard CommandLine.arguments.count == 4
      || (CommandLine.arguments.count == 5 && CommandLine.arguments[4] == "gpu") else {
      throw NSError(domain: "LiteRTQualification", code: 1)
    }
    let report = try await LiteRTUnifiedQualification.run(
      textURL: URL(fileURLWithPath: CommandLine.arguments[1]),
      embeddingURL: URL(fileURLWithPath: CommandLine.arguments[2]),
      cache: URL(fileURLWithPath: CommandLine.arguments[3]),
      backend: CommandLine.arguments.count == 5 ? .gpu : .cpu)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(report), as: UTF8.self))
  }
}
