import NativeAgentDomain

public enum SkillPromptLimits {
  /// Mobile-first bound. Full SKILL.md bodies are never part of this budget.
  public static let maximumSelectedSkills = 64
  public static let maximumCatalogUTF8Bytes = 12 * 1_024

  static func validate(_ skills: [ManagedSkill]) throws {
    guard skills.count <= maximumSelectedSkills else {
      throw AgentError.budgetExceeded(
        "Selected skill count exceeds the managed prompt limit of \(maximumSelectedSkills)."
      )
    }
    let byteCount = skills.reduce(into: 0) { total, skill in
      total += skill.name.utf8.count + skill.description.utf8.count + 4
    }
    guard byteCount <= maximumCatalogUTF8Bytes else {
      throw AgentError.budgetExceeded(
        "Selected skill catalog exceeds the managed prompt budget of \(maximumCatalogUTF8Bytes) UTF-8 bytes."
      )
    }
  }
}
