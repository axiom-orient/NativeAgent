import Foundation
import NativeAgentDomain

extension SkillLibrary {
    public func setSelected(skillName: String, selected: Bool) async throws {
        try await prepare()
        try await withLibraryAccess(kind: .selectionMutation) {
            let state = try await stateStore.load()
            let nextState = selectionReducer.setSelected(
                state: state,
                skillName: skillName,
                selected: selected
            )
            try await stateStore.save(nextState)
        }
    }

    public func setAllSelected(_ selected: Bool) async throws {
        try await prepare()
        try await withLibraryAccess(kind: .selectionMutation) {
            let state = try await stateStore.load()
            let currentSkills = try snapshotSkills(from: state)
            let nextState = selectionReducer.setAllSelected(
                state: state,
                skills: currentSkills,
                selected: selected
            )
            try await stateStore.save(nextState)
        }
    }
}
