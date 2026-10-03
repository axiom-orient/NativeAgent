import Foundation

struct SkillLibrarySnapshotBuilder {
    let groupOrder: (String) -> Int

    func sortCustomSkills(_ skills: [ManagedSkill]) -> [ManagedSkill] {
        skills.sorted { lhs, rhs in
            let lhsGroup = groupOrder(lhs.group)
            let rhsGroup = groupOrder(rhs.group)
            if lhsGroup != rhsGroup { return lhsGroup < rhsGroup }
            return lhs.name < rhs.name
        }
    }

    func mergeSkills(
        bundledSkills: [ManagedSkill],
        customSkills: [ManagedSkill]
    ) -> [ManagedSkill] {
        (bundledSkills + customSkills).sorted { lhs, rhs in
            let lhsGroup = groupOrder(lhs.group)
            let rhsGroup = groupOrder(rhs.group)
            if lhsGroup != rhsGroup { return lhsGroup < rhsGroup }
            if lhs.selected != rhs.selected { return lhs.selected && !rhs.selected }
            return lhs.name < rhs.name
        }
    }
}
