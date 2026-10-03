import Foundation
import NativeAgentDomain

public struct FilesToolPackConfiguration: Sendable, Equatable {
  public static let standardMaximumReadBytes = 1_000_000
  public static let standardMaximumWriteBytes = 1_000_000
  public static let standardMaximumSearchResults = 50
  public static let standardMaxVisitedNodes = 10_000
  public static let minimumPositiveLimit = 1

  public let maximumReadBytes: Int
  public let maximumWriteBytes: Int
  public let maximumSearchResults: Int
  public let maxVisitedNodes: Int
  public let readApprovalPolicy: ApprovalPolicy
  /// When true, changing an existing file requires the caller to provide the
  /// SHA-256 returned by `files.readText`. This is recommended for production
  /// hosts and prevents stale agent turns from overwriting newer content.
  public let requireExpectedSHA256ForOverwrite: Bool

  public init(
    maximumReadBytes: Int = Self.standardMaximumReadBytes,
    maximumWriteBytes: Int = Self.standardMaximumWriteBytes,
    maximumSearchResults: Int = Self.standardMaximumSearchResults,
    maxVisitedNodes: Int = Self.standardMaxVisitedNodes,
    readApprovalPolicy: ApprovalPolicy = .automatic,
    requireExpectedSHA256ForOverwrite: Bool = true
  ) {
    precondition(
      maximumReadBytes >= Self.minimumPositiveLimit, "maximumReadBytes must be positive.")
    precondition(
      maximumWriteBytes >= Self.minimumPositiveLimit, "maximumWriteBytes must be positive.")
    precondition(
      maximumSearchResults >= Self.minimumPositiveLimit, "maximumSearchResults must be positive.")
    precondition(maxVisitedNodes >= Self.minimumPositiveLimit, "maxVisitedNodes must be positive.")
    self.maximumReadBytes = maximumReadBytes
    self.maximumWriteBytes = maximumWriteBytes
    self.maximumSearchResults = maximumSearchResults
    self.maxVisitedNodes = maxVisitedNodes
    self.readApprovalPolicy = readApprovalPolicy
    self.requireExpectedSHA256ForOverwrite = requireExpectedSHA256ForOverwrite
  }

}

public struct FilesToolPack: ToolPack {
  public let packID = "toolpack.files"

  let pathResolver: FilesSandboxPathResolver
  let configuration: FilesToolPackConfiguration
  let instructionCatalog: InstructionDocumentCatalog
  let mutationCoordinator: FilesMutationCoordinator

  public init(
    rootURL: URL,
    configuration: FilesToolPackConfiguration = FilesToolPackConfiguration()
  ) {
    self.pathResolver = FilesSandboxPathResolver(rootURL: rootURL)
    self.configuration = configuration
    self.instructionCatalog = .makiLike
    self.mutationCoordinator = FilesMutationCoordinator()
  }

}
