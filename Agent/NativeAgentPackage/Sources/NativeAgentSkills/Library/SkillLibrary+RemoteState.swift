import NativeAgentDomain
import Foundation

extension SkillLibrary {
    func remoteStateSkills(from state: SkillState) -> [ManagedSkill] {
        state.remoteSkills
            .filter { $0.source.kind == .remote }
            .map { skill in
                applySelectionOverride(skill, from: state.selectionOverrides)
                    .applying(.groupChanged("custom"))
                    .applying(.excerptRefreshed)
            }
    }

    private func applySelectionOverride(_ skill: ManagedSkill, from overrides: [String: Bool])
        -> ManagedSkill
    {
        guard let override = overrides[skill.name] else { return skill }
        return skill.applying(.selectionChanged(override))
    }
}
