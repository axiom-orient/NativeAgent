import Foundation
import NativeAgentDomain
#if canImport(Security)
import Security
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public protocol SkillSecretStore: Sendable {
    func readSecret(for skillName: String) async throws -> String?
    func writeSecret(_ value: String, for skillName: String) async throws
    func deleteSecret(for skillName: String) async throws
    func hasSecret(for skillName: String) async throws -> Bool
}

struct SkillSecretFileWriter: Sendable {
    typealias ReplaceOperation = @Sendable (_ source: URL, _ destination: URL) throws -> Void

    private let replaceOperation: ReplaceOperation

    init(replaceOperation: @escaping ReplaceOperation = SkillSecretFileWriter.replaceAtomically) {
        self.replaceOperation = replaceOperation
    }

    func write(
        _ data: Data,
        to fileURL: URL,
        attributes: [FileAttributeKey: Any],
        fileManager: FileManager
    ) throws {
        let temporaryURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: attributes
        ) else {
            throw AgentError.persistenceFailure(
                "Skill secrets staging file could not be created."
            )
        }
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        // Reassert before publication in case the host filesystem ignored creation attributes.
        // There is no post-commit fallible metadata step: a reported save failure must not hide
        // that a replacement was already published.
        try fileManager.setAttributes(attributes, ofItemAtPath: temporaryURL.path)
        try replaceOperation(temporaryURL, fileURL)
    }

    private static func replaceAtomically(_ source: URL, _ destination: URL) throws {
        #if canImport(Darwin) || canImport(Glibc)
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            let errorCode = errno
            throw AgentError.persistenceFailure(
                "Skill secrets could not replace \(destination.lastPathComponent) (errno \(errorCode))."
            )
        }
        #else
        throw AgentError.persistenceFailure(
            "Atomic skill secret replacement is unsupported on this platform."
        )
        #endif
    }
}

public actor FileSkillSecretStore: SkillSecretStore {
    private struct SecretDocument: Codable, Sendable {
        static let currentVersion = "native-agent.skill.secrets/1"

        var version: String
        var secrets: [String: String]

        init(version: String = Self.currentVersion, secrets: [String: String] = [:]) {
            self.version = version
            self.secrets = secrets
        }

        private enum CodingKeys: String, CodingKey {
            case version
            case secrets
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let version = try container.decode(String.self, forKey: .version)
            guard version == Self.currentVersion else {
                throw DecodingError.dataCorruptedError(
                    forKey: .version,
                    in: container,
                    debugDescription: "Unsupported skill secrets version: \(version)."
                )
            }
            self.version = version
            self.secrets = try container.decode([String: String].self, forKey: .secrets)
        }
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let fileWriter: SkillSecretFileWriter

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.fileWriter = SkillSecretFileWriter()
    }

    init(
        fileURL: URL,
        fileManager: FileManager = .default,
        fileWriter: SkillSecretFileWriter
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.fileWriter = fileWriter
    }

    public func readSecret(for skillName: String) async throws -> String? {
        try loadDocument().secrets[skillName]
    }

    public func writeSecret(_ value: String, for skillName: String) async throws {
        var document = try loadDocument()
        document.secrets[skillName] = value
        try save(document)
    }

    public func deleteSecret(for skillName: String) async throws {
        var document = try loadDocument()
        document.secrets.removeValue(forKey: skillName)
        try save(document)
    }

    public func hasSecret(for skillName: String) async throws -> Bool {
        guard let value = try await readSecret(for: skillName) else { return false }
        return !value.isEmpty
    }

    private func loadDocument() throws -> SecretDocument {
        guard fileManager.fileExists(atPath: fileURL.path) else { return SecretDocument() }
        let data = try SkillBoundedFileReader.read(
            from: fileURL,
            maximumByteCount: SkillLocalFileLimits.maximumStateBytes,
            label: "Skill secrets"
        )
        return try JSONDecoder.nativeAgent().decode(SecretDocument.self, from: data)
    }

    private func save(_ document: SecretDocument) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.nativeAgent().encode(document)
        guard data.count <= SkillLocalFileLimits.maximumStateBytes else {
            throw AgentError.budgetExceeded(
                "Skill secrets exceed \(SkillLocalFileLimits.maximumStateBytes) bytes."
            )
        }

        var attributes: [FileAttributeKey: Any] = [
            .posixPermissions: 0o600
        ]
        #if os(iOS) || os(tvOS) || os(watchOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif

        // Stage an owner-only sibling and publish it with same-filesystem rename.
        // The previous secrets file remains authoritative until the replacement commits.
        try fileWriter.write(
            data,
            to: fileURL,
            attributes: attributes,
            fileManager: fileManager
        )
    }
}

#if canImport(Security)

enum SkillKeychainSecretPolicy {
    /// The default Apple credential namespace is app/installation scoped and
    /// keyed by skill name. A host that needs per-workspace credentials injects
    /// a distinct `SkillSecretStore` instead of changing the workspace path.
    static let defaultService = "NativeAgent.SkillSecrets"

    static func accessibility() -> CFString {
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    static func synchronizable() -> CFBoolean {
        kCFBooleanFalse!
    }
}

public actor KeychainSkillSecretStore: SkillSecretStore {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func readSecret(for skillName: String) async throws -> String? {
        var query = try baseQuery(for: skillName)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw AgentError.persistenceFailure("Keychain read failed: \(status)")
        }
    }

    public func writeSecret(_ value: String, for skillName: String) async throws {
        let data = Data(value.utf8)
        guard data.count <= SkillLocalFileLimits.maximumStateBytes else {
            throw AgentError.budgetExceeded(
                "Skill secret exceeds \(SkillLocalFileLimits.maximumStateBytes) UTF-8 bytes."
            )
        }
        let query = try baseQuery(for: skillName)
        let status = SecItemCopyMatching(
            query.merging([kSecReturnData as String: kCFBooleanTrue as Any], uniquingKeysWith: { $1 }) as CFDictionary,
            nil
        )
        if status == errSecSuccess {
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: SkillKeychainSecretPolicy.accessibility()
                ] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw AgentError.persistenceFailure("Keychain update failed: \(updateStatus)")
            }
            return
        }
        let addStatus = SecItemAdd(
            query.merging(
                [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: SkillKeychainSecretPolicy.accessibility()
                ],
                uniquingKeysWith: { $1 }
            ) as CFDictionary,
            nil
        )
        guard addStatus == errSecSuccess else {
            throw AgentError.persistenceFailure("Keychain add failed: \(addStatus)")
        }
    }

    public func deleteSecret(for skillName: String) async throws {
        let status = SecItemDelete(try baseQuery(for: skillName) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AgentError.persistenceFailure("Keychain delete failed: \(status)")
        }
    }

    public func hasSecret(for skillName: String) async throws -> Bool {
        var query = try baseQuery(for: skillName)
        query[kSecReturnData as String] = kCFBooleanFalse
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw AgentError.persistenceFailure("Keychain existence check failed: \(status)")
        }
    }

    private func baseQuery(for skillName: String) throws -> [String: Any] {
        guard service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AgentError.invalidConfiguration("Skill secret Keychain service must not be empty.")
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: skillName,
            kSecAttrSynchronizable as String: SkillKeychainSecretPolicy.synchronizable()
        ]
    }
}
#endif


public enum SkillSecrets {
    /// Returns the platform default secret owner. On Apple platforms the
    /// Keychain namespace is intentionally app/installation scoped rather than
    /// workspace scoped. Hosts requiring different credential scopes provide a
    /// custom `SkillSecretStore` when constructing `SkillLibrary`.
    public static func makeDefaultStore(workspace: SkillWorkspace) -> any SkillSecretStore {
        #if canImport(Security)
        return KeychainSkillSecretStore(service: SkillKeychainSecretPolicy.defaultService)
        #else
        return FileSkillSecretStore(fileURL: workspace.secretsFileURL)
        #endif
    }
}
