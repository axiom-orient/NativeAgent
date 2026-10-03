import Foundation
import Testing

struct FunctionalPackageBoundaryTests {
    private static let expectedDependencies: [String: Set<String>] = [
        "KnowledgeCore": [],
        "HTMLDocument": [],
        "DocumentCore": [],
        "DocumentRuntime": ["DocumentCore"],
        "HWPDocument": ["DocumentCore", "DocumentRuntime"],
        "DocumentUI": ["DocumentCore", "HWPDocument"],
        "PageIndex": ["KnowledgeCore", "DocumentCore"],
        "EvidenceIndex": ["PageIndex"],
        "KnowledgeRuntime": ["KnowledgeCore"],
        "KnowledgeHealth": ["KnowledgeRuntime", "EvidenceIndex"],
        "SourceCapture": ["KnowledgeCore", "KnowledgeRuntime", "HTMLDocument"],
        "WorkWiki": ["KnowledgeCore", "KnowledgeRuntime", "EvidenceIndex", "PageIndex"],
        "KnowledgePresentation": ["KnowledgeCore", "KnowledgeRuntime", "DocumentCore", "DocumentRuntime", "PageIndex"],
        "ASKTutor": ["ASK", "KnowledgeCore", "KnowledgeRuntime", "EvidenceIndex", "PageIndex", "DocumentCore", "DocumentRuntime", "KnowledgePresentation"],
        "ASKApplication": ["KnowledgeRuntime", "KnowledgeHealth", "EvidenceIndex", "WorkWiki"],
        "MarkdownWiki": [],
        "ASKFoundationModels": ["ASK"],
        "ASKMCP": ["ASK", "KnowledgeCore"],
        "ASKAgentTools": ["ASK", "NativeAgent", "LanguageModelCore"],
    ]

    @Test
    func repositoryUsesIndependentFunctionalPackages() throws {
        let root = try repositoryRoot()
        let packagesRoot = root.appendingPathComponent("Packages", isDirectory: true)

        for packageName in Self.expectedDependencies.keys.sorted() {
            let packageRoot = packagesRoot.appendingPathComponent(packageName, isDirectory: true)
            #expect(FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent("Package.swift").path))
            #expect(FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent("Sources/\(packageName)").path))
        }
    }

    @Test
    func packageDependencyGraphMatchesAllowedDirection() throws {
        let root = try repositoryRoot()

        for (packageName, expected) in Self.expectedDependencies {
            let manifestURL = root.appendingPathComponent("Packages/\(packageName)/Package.swift")
            let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
            let packageRoot = manifestURL.deletingLastPathComponent()
            let actual = Set(manifest.components(separatedBy: .newlines).compactMap { line -> String? in
                guard line.contains(".package(") else { return nil }
                guard let pathLabel = line.range(of: "path: \"") else { return nil }
                let remainder = line[pathLabel.upperBound...]
                guard let end = remainder.firstIndex(of: "\"") else { return nil }
                let dependencyURL = packageRoot
                    .appendingPathComponent(String(remainder[..<end]), isDirectory: true)
                    .standardizedFileURL
                return dependencyURL.path == root.standardizedFileURL.path
                    ? "ASK"
                    : dependencyURL.lastPathComponent
            })
            #expect(actual == expected, "\(packageName) dependency drift: expected \(expected.sorted()), got \(actual.sorted())")
        }
    }

    @Test
    func dependencyGraphIsAcyclic() {
        var visiting: Set<String> = []
        var visited: Set<String> = []

        func visit(_ package: String) -> Bool {
            if visiting.contains(package) { return false }
            if visited.contains(package) { return true }
            visiting.insert(package)
            for dependency in Self.expectedDependencies[package, default: []] {
                guard visit(dependency) else { return false }
            }
            visiting.remove(package)
            visited.insert(package)
            return true
        }

        for package in Self.expectedDependencies.keys {
            #expect(visit(package), "Dependency cycle includes \(package)")
        }
    }

    @Test
    func rootFacadeDependsOnlyOnUsedFeatures() throws {
        let root = try repositoryRoot()
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)

        for required in [
            "KnowledgeCore",
            "KnowledgeRuntime",
            "EvidenceIndex",
            "DocumentCore",
            "WorkWiki",
            "KnowledgeHealth",
            "KnowledgePresentation",
        ] {
            #expect(manifest.contains("Packages/\(required)"))
        }
        #expect(!manifest.contains("Packages/ASKAgentTools"))
        #expect(!manifest.contains("NativeAgent"))
        #expect(!manifest.contains("Packages/SourceCapture"))
        #expect(manifest.contains("Packages/ASKApplication"))
        #expect(!manifest.contains("Packages/HTMLDocument"))
    }

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Packages/KnowledgeCore/Package.swift").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw BoundaryTestError.repositoryRootNotFound
            }
            directory = parent
        }
        return directory
    }
}

private enum BoundaryTestError: Error {
    case repositoryRootNotFound
}
