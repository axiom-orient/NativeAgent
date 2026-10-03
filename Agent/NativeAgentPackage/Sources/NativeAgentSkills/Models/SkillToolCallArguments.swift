import Foundation
import NativeAgentDomain

struct SkillLoadToolCallArguments: Sendable {
    let skillName: String

    init(_ arguments: JSONValue) throws {
        self.skillName = try arguments.stringField("skill_name")
    }
}


struct SkillReadFileToolCallArguments: Sendable {
    let skillName: String
    let relativePath: String
    let characterOffset: Int
    let maxCharacters: Int

    init(_ arguments: JSONValue) throws {
        self.skillName = try arguments.stringField("skill_name")
        self.relativePath = try arguments.stringField("path")
        self.characterOffset = arguments.optionalIntField("character_offset") ?? 0
        self.maxCharacters = arguments.optionalIntField("max_characters") ?? SkillSupportingFileRead.defaultCharactersPerRead
    }
}

struct SkillRunJSToolCallArguments: Sendable {
    let skillName: String
    let scriptName: String
    let dataJSONString: String

    init(_ arguments: JSONValue) throws {
        self.skillName = try arguments.stringField("skill_name")
        self.scriptName = arguments.optionalStringField("script_name") ?? "index.html"
        self.dataJSONString = try SkillJSONPayloadSupport.canonicalJSONString(
            forField: "data",
            in: arguments
        )
    }
}

struct SkillRunIntentToolCallArguments: Sendable {
    let intent: String
    let parametersJSON: String

    init(_ arguments: JSONValue) throws {
        self.intent = try arguments.stringField("intent")
        self.parametersJSON = try SkillJSONPayloadSupport.canonicalJSONString(
            forField: "parameters",
            in: arguments,
            requireJSONObject: true
        )
    }
}
