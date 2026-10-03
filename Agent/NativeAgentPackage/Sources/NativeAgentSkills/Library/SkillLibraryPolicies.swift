import Foundation
import NativeAgentDomain

struct SkillLibrarySelectionReducer {
    let now: @Sendable () -> Date

    func setSelected(
        state: SkillState,
        skillName: String,
        selected: Bool
    ) -> SkillState {
        let timestamp = now()
        return applySelectionOverride(
            to: state,
            skillName: skillName,
            selected: selected,
            updatedAt: timestamp
        )
    }

    func setAllSelected(
        state: SkillState,
        skills: [ManagedSkill],
        selected: Bool
    ) -> SkillState {
        let timestamp = now()
        var next = state
        for skill in skills {
            next = applySelectionOverride(
                to: next,
                skillName: skill.name,
                selected: selected,
                updatedAt: timestamp
            )
        }
        return next
    }

    private func applySelectionOverride(
        to state: SkillState,
        skillName: String,
        selected: Bool,
        updatedAt: Date
    ) -> SkillState {
        var remoteSkills = state.remoteSkills
        updateSelection(in: &remoteSkills, skillName: skillName, selected: selected, updatedAt: updatedAt)
        return state.applying(
            .contentsChanged(
                selectionOverrides: state.selectionOverrides.merging([skillName: selected]) { _, new in new },
                remoteSkills: remoteSkills,
                installedPlugins: state.installedPlugins,
                updatedAt: updatedAt
            )
        )
    }

    private func updateSelection(
        in skills: inout [ManagedSkill],
        skillName: String,
        selected: Bool,
        updatedAt: Date
    ) {
        guard let index = skills.firstIndex(where: { $0.name == skillName }) else {
            return
        }

        skills[index] = skills[index].applying(.selectionChanged(selected, updatedAt: updatedAt))
    }
}
