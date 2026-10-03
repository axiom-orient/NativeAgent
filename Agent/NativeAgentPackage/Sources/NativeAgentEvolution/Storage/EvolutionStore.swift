import NativeAgentDomain
import Foundation

public struct FileEvolutionReportStore: EvolutionReportStore {
    public let rootURL: URL
    private let coordinator: EvolutionReportStoreCoordinator

    public init(rootURL: URL) {
        let standardizedRoot = rootURL.standardizedFileURL
        self.rootURL = standardizedRoot
        self.coordinator = EvolutionReportStoreCoordinator(rootURL: standardizedRoot)
    }

    public func save(_ report: EvolutionReport) async throws -> EvolutionReport {
        do {
            return try await coordinator.save(report)
        } catch let error as EvolutionError {
            throw error
        } catch {
            throw EvolutionError.storeFailure(
                "failed to save evolution report \"\(report.runID)\": \(error.localizedDescription)")
        }
    }

    public func path(runID: String) -> String {
        rootURL.appendingPathComponent(
            EvolutionPath.sanitized(runID),
            isDirectory: true
        ).path
    }
}

private actor EvolutionReportStoreCoordinator {
    private let rootURL: URL
    private let transaction: EvolutionReportDirectoryTransaction
    private let planner = EvolutionReportStoragePlanner()

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.transaction = EvolutionReportDirectoryTransaction(
            rootURL: rootURL,
            fileManager: fileManager
        )
    }

    func save(_ report: EvolutionReport) throws -> EvolutionReport {
        let destination = rootURL.appendingPathComponent(
            EvolutionPath.sanitized(report.runID),
            isDirectory: true
        )
        let plan = try planner.plan(
            report: report,
            destinationPath: destination.path
        )
        do {
            try transaction.perform(plan)
            return plan.storedReport
        } catch {
            throw EvolutionError.storeFailure(
                "failed to save evolution report \"\(report.runID)\": \(error.localizedDescription)")
        }
    }
}
