import Foundation
import PageIndex

struct ASKEvidenceFreshnessEvaluation: Sendable, Equatable {
  let status: ASKEvidenceFreshnessStatus
  let currentChecksum: String?
}

/// Filesystem effect adapter for comparing an indexed artifact with its original source.
struct ASKEvidenceFreshnessInspector: Sendable {
  func evaluate(
    _ artifact: SourceIndexArtifact
  ) throws -> ASKEvidenceFreshnessEvaluation {
    guard let sourcePath = artifact.sourcePath, !sourcePath.isEmpty else {
      return ASKEvidenceFreshnessEvaluation(status: .unknown, currentChecksum: nil)
    }

    let evaluation: ASKEvidenceFreshnessEvaluation
    do {
      let version = try currentVersion(for: sourcePath)
      evaluation = ASKEvidenceFreshnessEvaluation(
        status: version.checksum == artifact.version.checksum ? .ok : .stale,
        currentChecksum: version.checksum
      )
    } catch let error as CocoaError
      where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
    {
      evaluation = ASKEvidenceFreshnessEvaluation(status: .missing, currentChecksum: nil)
    }
    return evaluation
  }

  private func currentVersion(for sourcePath: String) throws -> SourceVersion {
    let url = URL(fileURLWithPath: sourcePath)
    let data = try Data(contentsOf: url)
    let attributes = try FileManager.default.attributesOfItem(atPath: sourcePath)
    let modifiedAt = attributes[.modificationDate] as? Date
    return SourceIdentityFactory.makeVersion(data: data, modifiedAt: modifiedAt)
  }
}
