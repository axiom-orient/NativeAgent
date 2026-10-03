import Foundation
import Testing
@testable import ASK

@Test func planningIsHeadlessAndCannotExecuteBeforeValidation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let configuration = ASKConfiguration(workspaceURL: root)
    let client = ASKClient(configuration: configuration)
    let command = ASKCommand.indexWorkspace(.init(sourceRootURL: root.appendingPathComponent("source")))
    let plan = try client.plan(command)
    #expect(try client.plan(command) == plan)
    _ = try client.dryRun(plan)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    #expect(throws: ASKDiagnostic.self) {
        try ASKCommandExecutionReducer.reduce(state: .planned(plan), event: .begin)
    }
    let validated = try ASKCommandExecutionReducer.reduce(state: .planned(plan), event: .validate(configuration))
    #expect(validated.effect == .none)
    let applying = try ASKCommandExecutionReducer.reduce(state: validated.state, event: .begin)
    #expect(applying.effect == .execute(plan))
    #expect(!FileManager.default.fileExists(atPath: root.path))
}
