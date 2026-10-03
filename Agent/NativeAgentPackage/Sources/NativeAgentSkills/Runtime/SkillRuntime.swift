import Foundation
import NativeAgentDomain

public struct SkillRuntime: SkillRuntimeClient {
    let selectedSkillsLoader: @Sendable () async throws -> [ManagedSkill]
    let selectedSkillLoader: @Sendable (String) async throws -> ManagedSkill?
    let supportingFileLoader: @Sendable (ManagedSkill) async throws -> [SkillSupportingFileSummary]
    let supportingFileReader: @Sendable (ManagedSkill, String, Int, Int) async throws -> SkillSupportingFileRead
    let scriptURLResolver: @Sendable (ManagedSkill, String) async throws -> URL
    let readAccessURLResolver: @Sendable (ManagedSkill) async throws -> URL?
    let webViewURLResolver: @Sendable (ManagedSkill, String) async throws -> URL
    let secretReader: @Sendable (String) async throws -> String?
    let scriptRunner: any SkillScriptRunner
    let intentService: any SkillIntentService
    let resultBuilder = SkillRuntimeResultBuilder()

    public init(
        library: SkillLibrary,
        scriptRunner: any SkillScriptRunner,
        intentService: any SkillIntentService
    ) {
        self.init(
            selectedSkillsLoader: { try await library.selectedSkills() },
            selectedSkillLoader: { name in
                guard let skill = try await library.skill(named: name), skill.selected else { return nil }
                return skill
            },
            supportingFileLoader: { skill in try await library.supportingFiles(for: skill) },
            supportingFileReader: { skill, path, offset, limit in
                try await library.readSupportingFile(
                    for: skill,
                    relativePath: path,
                    characterOffset: offset,
                    maxCharacters: limit
                )
            },
            scriptURLResolver: { skill, scriptName in
                try await library.resolveScriptURL(for: skill, scriptName: scriptName)
            },
            readAccessURLResolver: { skill in
                switch skill.source.kind {
                case .bundled, .imported, .plugin, .web:
                    return try await library.skillDirectoryURL(for: skill)
                case .remote:
                    return nil
                }
            },
            webViewURLResolver: { skill, urlString in
                try await library.resolveWebViewURL(for: skill, urlString: urlString)
            },
            secretReader: { skillName in try await library.readSecret(for: skillName) },
            scriptRunner: scriptRunner,
            intentService: intentService
        )
    }

    init(
        library: SkillLibrary,
        scriptRunner: any SkillScriptRunner,
        intentService: any SkillIntentService,
        supportingFileLoader: @escaping @Sendable (ManagedSkill) async throws -> [SkillSupportingFileSummary]
    ) {
        self.init(
            selectedSkillsLoader: { try await library.selectedSkills() },
            selectedSkillLoader: { name in
                guard let skill = try await library.skill(named: name), skill.selected else { return nil }
                return skill
            },
            supportingFileLoader: supportingFileLoader,
            supportingFileReader: { skill, path, offset, limit in
                try await library.readSupportingFile(
                    for: skill,
                    relativePath: path,
                    characterOffset: offset,
                    maxCharacters: limit
                )
            },
            scriptURLResolver: { skill, scriptName in
                try await library.resolveScriptURL(for: skill, scriptName: scriptName)
            },
            readAccessURLResolver: { skill in
                switch skill.source.kind {
                case .bundled, .imported, .plugin, .web:
                    return try await library.skillDirectoryURL(for: skill)
                case .remote:
                    return nil
                }
            },
            webViewURLResolver: { skill, urlString in
                try await library.resolveWebViewURL(for: skill, urlString: urlString)
            },
            secretReader: { skillName in try await library.readSecret(for: skillName) },
            scriptRunner: scriptRunner,
            intentService: intentService
        )
    }

    package init(
        selectedSkillsLoader: @escaping @Sendable () async throws -> [ManagedSkill],
        selectedSkillLoader: @escaping @Sendable (String) async throws -> ManagedSkill?,
        supportingFileLoader: @escaping @Sendable (ManagedSkill) async throws -> [SkillSupportingFileSummary],
        supportingFileReader: @escaping @Sendable (ManagedSkill, String, Int, Int) async throws -> SkillSupportingFileRead,
        scriptURLResolver: @escaping @Sendable (ManagedSkill, String) async throws -> URL,
        readAccessURLResolver: @escaping @Sendable (ManagedSkill) async throws -> URL?,
        webViewURLResolver: @escaping @Sendable (ManagedSkill, String) async throws -> URL,
        secretReader: @escaping @Sendable (String) async throws -> String?,
        scriptRunner: any SkillScriptRunner,
        intentService: any SkillIntentService
    ) {
        self.selectedSkillsLoader = selectedSkillsLoader
        self.selectedSkillLoader = selectedSkillLoader
        self.supportingFileLoader = supportingFileLoader
        self.supportingFileReader = supportingFileReader
        self.scriptURLResolver = scriptURLResolver
        self.readAccessURLResolver = readAccessURLResolver
        self.webViewURLResolver = webViewURLResolver
        self.secretReader = secretReader
        self.scriptRunner = scriptRunner
        self.intentService = intentService
    }
}
