import ASK
import XCTest

final class ASKPackageBoundaryTests: XCTestCase {
    func testRootProductIsLibraryOnly() throws {
        let root = try repositoryRoot()
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let compact = manifest.filter { !$0.isWhitespace }

        XCTAssertTrue(compact.contains(#".library(name:"ASK",targets:["ASK"])"#))
        XCTAssertEqual(compact.components(separatedBy: ".library(").count - 1, 1)
        XCTAssertFalse(manifest.contains(".executable(name:"))
        XCTAssertFalse(manifest.contains(".executableTarget("))
    }

    func testASKPublicFacadeAllowlist() throws {
        let root = try repositoryRoot()
        let source = try swiftSources(under: root.appendingPathComponent("Sources/ASK"))
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let publicTopLevelNames = Set(
            source
                .split(separator: "\n")
                .compactMap { line -> String? in
                    guard line.hasPrefix("public ") else { return nil }
                    let tokens = line.split { $0 == " " || $0 == ":" || $0 == "(" }
                    guard tokens.count >= 3 else { return nil }
                    let kind = String(tokens[1])
                    guard ["struct", "enum"].contains(kind) else { return nil }
                    return String(tokens[2])
                }
        )

        let required = Set([
            "ASKClient", "ASKConfiguration", "ASKCommand", "ASKCommandPlan",
            "ASKApplyOutcome", "ASKQuery", "ASKQueryResult", "ASKDiagnostic",
        ])
        XCTAssertTrue(required.isSubset(of: publicTopLevelNames), "Missing public contracts: \(required.subtracting(publicTopLevelNames))")
        let forbidden = Set(["ASKApplicationRuntime", "ASKMobileHost", "ASKWorkflowRouter", "ASKWorkWikiRuntime"])
        let publicSurfaceLines = source
            .split(separator: "\n")
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("public ") || trimmed.contains(" public ")
            }
        let leakedPublicLines = publicSurfaceLines.filter { line in
            forbidden.contains { line.contains($0) }
        }
        XCTAssertTrue(leakedPublicLines.isEmpty, "Application internals leaked from root public declarations: \(leakedPublicLines)")
    }

    func testCanonicalSourceAndTestRootsExist() throws {
        let root = try repositoryRoot()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/ASK").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Tests/ASKTests").path))

        for package in try functionalPackageDirectories(root: root) {
            let packageName = package.lastPathComponent
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: package.appendingPathComponent("Sources/\(packageName)").path),
                "Missing canonical source root for \(packageName)"
            )
        }
    }

    func testActiveSwiftSourcesAreNotEmpty() throws {
        let root = try repositoryRoot()
        let packageSourceRoots = try functionalPackageDirectories(root: root).map {
            $0.appendingPathComponent("Sources")
        }
        let sourceRoots = [root.appendingPathComponent("Sources")] + packageSourceRoots
        var emptySources: [String] = []

        for sourceRoot in sourceRoots where FileManager.default.fileExists(atPath: sourceRoot.path) {
            for url in try swiftSources(under: sourceRoot) {
                let source = try String(contentsOf: url, encoding: .utf8)
                if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emptySources.append(relative(url, to: root))
                }
            }
        }

        XCTAssertTrue(emptySources.isEmpty, "Empty Swift sources: \(emptySources)")
    }

    func testSDKDoesNotOwnProductAppComposition() throws {
        let askRoot = try repositoryRoot()
        let workspaceRoot = askRoot.deletingLastPathComponent()
        let askManifest = try String(contentsOf: askRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertFalse(askManifest.contains("NativeAgent"), "ASK must remain independent from the agent runtime")

        let appsRoot = workspaceRoot.appendingPathComponent("Apps", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: appsRoot.path), "SDK workspace must not own a production app composition root")

        let integrationsRoot = workspaceRoot.appendingPathComponent("Integrations", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: integrationsRoot.path), "SDK workspace must not own a shared Agent+ASK integration layer without an independent contract")

        let verificationRoot = workspaceRoot.appendingPathComponent("Verification", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: verificationRoot.path), "SDK workspace must not own a synthetic consumer composition package")
    }

    func testMarkdownWikiIsSelectedOnlyFromItsIndependentPackage() throws {
        let root = try repositoryRoot()
        let rootManifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let markdownManifest = try String(
            contentsOf: root.appendingPathComponent("Packages/MarkdownWiki/Package.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(rootManifest.contains("Packages/MarkdownWiki"))
        XCTAssertFalse(rootManifest.contains("ASKMarkdownWiki"))
        XCTAssertTrue(markdownManifest.contains(#"name: "MarkdownWiki""#))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/ASKMarkdownWiki").path))
    }

    func testASKFacadeKeepsIntegrityAndStateTransitionGates() throws {
        let root = try repositoryRoot()
        let source = try swiftSources(under: root.appendingPathComponent("Sources/ASK"))
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertTrue(source.contains("mapASKDiagnostic"))
        XCTAssertTrue(source.contains("ASKCommandPlanIntegrity.verify"))
        XCTAssertTrue(source.contains("ASKCommandExecutionReducer"))
    }

    func testPackageSourcesDoNotCreateUnownedTasks() throws {
        let root = try repositoryRoot()
        let packageSourceRoots = try functionalPackageDirectories(root: root).map {
            $0.appendingPathComponent("Sources")
        }
        let sourceRoots = [root.appendingPathComponent("Sources")] + packageSourceRoots
        let forbidden = ["Task {", "Task.detached"]
        var offenders: [String] = []

        for sourceRoot in sourceRoots {
            for url in try swiftSources(under: sourceRoot) {
                let source = try String(contentsOf: url, encoding: .utf8)
                for token in forbidden where source.contains(token) {
                    offenders.append("\(relative(url, to: root)):\(token)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "Unowned asynchronous work: \(offenders)")
    }

    func testProductionSourcesExcludeVerificationHarnessesAndRemovedCompatibilitySurface() throws {
        let root = try repositoryRoot()
        let packageSourceRoots = try functionalPackageDirectories(root: root).map {
            $0.appendingPathComponent("Sources")
        }
        let sourceRoots = [root.appendingPathComponent("Sources")] + packageSourceRoots
        let forbiddenFileNames: Set<String> = [
            "ASKHWPFixtureValidation.swift",
            "ASKHWPGoldenRegression.swift",
            "ASKHWPReferenceRasterValidation.swift",
            "RuntimeAPI.swift",
        ]
        let forbiddenDeclarations = [
            "public typealias ASKMobile =",
            "public typealias ImportedCapture =",
            "public typealias MDSwiftError =",
            "public typealias ValidationError = ASKError",
            "public typealias ReviewQueueSnapshot =",
            "public typealias LintReport =",
            "public typealias TutorSolveModelRequest =",
            "typealias SoupCoreError =",
            "struct ASKMobileClient",
            "struct ASKMobileHost",
            "struct ASKWorkflowRouter",
            "struct ASKMobileConfiguration",
            "struct ASKApplicationStateSummary",
            "struct ASKAgentContract",
            "struct ASKAgentSearchRequest",
            "enum ASKWorkflowRouterError",
            "sweepLegacyRecordTree",
            "legacyDirectories",
        ]
        var offenders: [String] = []

        for sourceRoot in sourceRoots {
            for url in try swiftSources(under: sourceRoot) {
                let path = relative(url, to: root)
                if forbiddenFileNames.contains(url.lastPathComponent) {
                    offenders.append(path)
                }
                let source = try String(contentsOf: url, encoding: .utf8)
                for declaration in forbiddenDeclarations where source.contains(declaration) {
                    offenders.append("\(path):\(declaration)")
                }
            }
        }

        XCTAssertTrue(offenders.isEmpty, "Non-product compatibility or verification surface: \(offenders)")
    }

    func testKnowledgeCoreRemainsDeterministicAndEffectFree() throws {
        let root = try repositoryRoot()
        let coreRoot = root.appendingPathComponent("Packages/KnowledgeCore/Sources/KnowledgeCore")
        let forbidden = [
            "FileManager", "URLSession", "UserDefaults", "Date()", "UUID()",
            "Task {", "Task.detached", "print(", "fatalError", "preconditionFailure",
        ]
        var offenders: [String] = []
        for url in try swiftSources(under: coreRoot) {
            let source = try String(contentsOf: url, encoding: .utf8)
            for token in forbidden where source.contains(token) {
                offenders.append("\(relative(url, to: root)):\(token)")
            }
        }
        XCTAssertTrue(offenders.isEmpty, "KnowledgeCore effect leak: \(offenders)")
    }

    func testTutorDomainIDsAreDeterministic() throws {
        let root = try repositoryRoot()
        let checkedRoots = [
            root.appendingPathComponent("Packages/ASKTutor/Sources/ASKTutor/TutorCore"),
            root.appendingPathComponent("Packages/ASKTutor/Sources/ASKTutor/TutorInsight"),
        ]
        var offenders: [String] = []
        for checkedRoot in checkedRoots {
            for url in try swiftSources(under: checkedRoot) {
                if try String(contentsOf: url, encoding: .utf8).contains("UUID()") {
                    offenders.append(relative(url, to: root))
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "Random tutor domain IDs: \(offenders)")
    }

    func testRepositoryHasNoFinderMetadata() throws {
        let root = try repositoryRoot()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return XCTFail("Unable to enumerate repository")
        }
        var offenders: [String] = []
        for case let url as URL in enumerator {
            if Self.generatedDirectoryNames.contains(url.lastPathComponent),
               (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                enumerator.skipDescendants()
                continue
            }
            if url.lastPathComponent == ".DS_Store" {
                offenders.append(relative(url, to: root))
            }
        }
        XCTAssertTrue(offenders.isEmpty, "Finder metadata: \(offenders)")
    }

    /// Build products are not repository sources; scanning them makes this check
    /// both slow and dependent on transient tooling output.
    private static let generatedDirectoryNames: Set<String> = [
        ".build", ".swiftpm", "DerivedData", ".git",
    ]

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Packages/KnowledgeCore/Package.swift").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw TestSupportError.repositoryRootNotFound
            }
            directory = parent
        }
        return directory
    }

    private func functionalPackageDirectories(root: URL) throws -> [URL] {
        let packagesRoot = root.appendingPathComponent("Packages", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(
            at: packagesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Package.swift").path) }
    }

    private func swiftSources(under root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw TestSupportError.missingDirectory(root.path)
        }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw TestSupportError.unreadableDirectory(root.path)
        }
        return enumerator.compactMap { entry in
            guard let url = entry as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    private func relative(_ url: URL, to root: URL) -> String {
        url.path.replacingOccurrences(of: root.path + "/", with: "")
    }
}

private enum TestSupportError: Error {
    case repositoryRootNotFound
    case missingDirectory(String)
    case unreadableDirectory(String)
}
