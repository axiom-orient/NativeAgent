import Foundation
import Synchronization
import Testing

@testable import NativeAgentDomain
@testable import NativeAgentSkills

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

actor RecordingSecretStore: SkillSecretStore {
    private var configuredSkills: Set<String>
    private var queriedSkillNames: [String] = []
    private var deletedSkillNames: [String] = []

    init(configuredSkills: Set<String> = []) {
        self.configuredSkills = configuredSkills
    }

    func readSecret(for skillName: String) async throws -> String? {
        configuredSkills.contains(skillName) ? "configured" : nil
    }

    func writeSecret(_ value: String, for skillName: String) async throws {
        configuredSkills.insert(skillName)
    }

    func deleteSecret(for skillName: String) async throws {
        configuredSkills.remove(skillName)
        deletedSkillNames.append(skillName)
    }

    func hasSecret(for skillName: String) async throws -> Bool {
        queriedSkillNames.append(skillName)
        return configuredSkills.contains(skillName)
    }

    func queriedNames() -> [String] {
        queriedSkillNames
    }

    func deletedNames() -> [String] {
        deletedSkillNames
    }
}

actor ConcurrentSecretStore: SkillSecretStore {
    private let configuredSkills: Set<String>
    private let delayNanoseconds: UInt64
    private var queriedSkillNames: [String] = []
    private var activeCalls = 0
    private var maxConcurrentCalls = 0

    init(configuredSkills: Set<String>, delayNanoseconds: UInt64 = 50_000_000) {
        self.configuredSkills = configuredSkills
        self.delayNanoseconds = delayNanoseconds
    }

    func readSecret(for skillName: String) async throws -> String? {
        configuredSkills.contains(skillName) ? "configured" : nil
    }

    func writeSecret(_ value: String, for skillName: String) async throws {}

    func deleteSecret(for skillName: String) async throws {}

    func hasSecret(for skillName: String) async throws -> Bool {
        queriedSkillNames.append(skillName)
        activeCalls += 1
        maxConcurrentCalls = max(maxConcurrentCalls, activeCalls)

        defer {
            activeCalls -= 1
        }

        try await Task.sleep(nanoseconds: delayNanoseconds)
        return configuredSkills.contains(skillName)
    }

    func snapshot() -> (queriedNames: [String], maxConcurrentCalls: Int) {
        (queriedSkillNames, maxConcurrentCalls)
    }
}

actor BlockingSecretStore: SkillSecretStore {
    private var writeStarted = false
    private var writeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var writeRelease: CheckedContinuation<Void, Never>?
    private var releaseRequested = false
    private var writes: [(String, String)] = []

    func readSecret(for skillName: String) async throws -> String? { nil }

    func writeSecret(_ value: String, for skillName: String) async throws {
        writeStarted = true
        let waiters = writeStartWaiters
        writeStartWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if releaseRequested {
            releaseRequested = false
        } else {
            await withCheckedContinuation { continuation in
                writeRelease = continuation
            }
        }
        writes.append((skillName, value))
    }

    func deleteSecret(for skillName: String) async throws {}
    func hasSecret(for skillName: String) async throws -> Bool { false }

    func waitForWriteToStart() async {
        if writeStarted { return }
        await withCheckedContinuation { continuation in
            writeStartWaiters.append(continuation)
        }
    }

    func releaseWrite() {
        if let writeRelease {
            self.writeRelease = nil
            writeRelease.resume()
        } else {
            releaseRequested = true
        }
    }

    func recordedWrites() -> [(String, String)] { writes }
}

actor CountingSecretStore: SkillSecretStore {
    private var writeCount = 0

    func readSecret(for skillName: String) async throws -> String? { nil }
    func writeSecret(_ value: String, for skillName: String) async throws { writeCount += 1 }
    func deleteSecret(for skillName: String) async throws {}
    func hasSecret(for skillName: String) async throws -> Bool { false }

    func recordedWriteCount() -> Int { writeCount }
}
