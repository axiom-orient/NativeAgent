import Foundation
import NativeAgentDomain

extension FilesToolPack {
    public func executors() -> [any ToolExecutor] {
        [
            makeListExecutor(),
            makeSearchExecutor(),
            makeReadExecutor(),
            makeWriteExecutor(),
            makeReplaceExecutor(),
            makeDeleteExecutor(),
            makeInitInstructionExecutor()
        ]
    }

    func makeListExecutor() -> ClosureToolExecutor {
        ClosureToolExecutor(definition: listDefinition) { call, _ in
            try executeList(call)
        }
    }

    func makeSearchExecutor() -> ClosureToolExecutor {
        ClosureToolExecutor(definition: searchDefinition) { call, _ in
            try executeSearch(call)
        }
    }

    func makeReadExecutor() -> ClosureToolExecutor {
        ClosureToolExecutor(definition: readDefinition) { call, _ in
            try executeReadText(call)
        }
    }

    func makeWriteExecutor() -> ClosureToolExecutor {
        ClosureToolExecutor(definition: writeDefinition) { call, _ in
            try await executeWriteText(call)
        }
    }

    func makeReplaceExecutor() -> ClosureToolExecutor {
        ClosureToolExecutor(definition: replaceDefinition) { call, _ in
            try await executeReplaceText(call)
        }
    }

    func makeDeleteExecutor() -> ClosureToolExecutor {
        ClosureToolExecutor(definition: deleteDefinition) { call, _ in
            try await executeDelete(call)
        }
    }

    func makeInitInstructionExecutor() -> ClosureToolExecutor {
        ClosureToolExecutor(definition: initInstructionDefinition) { call, _ in
            try await executeInitInstruction(call)
        }
    }
}
