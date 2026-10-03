#!/usr/bin/env python3
"""Build an explicitly limited verification package from byte-identical sources.
No substitutes for unavailable providers. This is not the root product build.
Usage: python3 Verification/OwnerChecks/prepare.py /absolute/new/output
"""
import hashlib
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    output = Path(sys.argv[1]).expanduser().resolve()
    if output.exists() or output == ROOT or ROOT in output.parents:
        raise SystemExit("Choose a new directory outside the source repository")
    output.mkdir(parents=True)
    copied = {}

    def copy(paths, directory):
        for source in sorted(paths):
            if source.is_dir():
                continue
            if not source.is_file():
                raise FileNotFoundError(source)
            destination = output / directory / source.name
            if destination.exists():
                raise RuntimeError(f"Duplicate filename: {source}")
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
            copied[str(source.relative_to(ROOT))] = hashlib.sha256(source.read_bytes()).hexdigest()

    def tree(source_root, directory):
        if not source_root.is_dir():
            raise FileNotFoundError(source_root)
        for source in sorted(source_root.rglob("*")):
            if source.is_file():
                destination = output / directory / source.relative_to(source_root)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)
                copied[str(source.relative_to(ROOT))] = hashlib.sha256(source.read_bytes()).hexdigest()

    def sources(package, part=""):
        return (ROOT / f"Packages/{package}/Sources/{package}" / part).rglob("*.swift")

    for part in ["Core", "Workspace", "RAG"]:
        copy((p for p in sources("PageIndex", part) if p.name != "SourceArtifacts.swift"), "Sources/PageIndex")
    copy((ROOT / "Packages/PageIndex/Sources/PageIndex/Resources").rglob("*"), "Sources/PageIndex/Resources")
    for module in ["EvidenceIndex", "HTMLDocument"]:
        copy(sources(module), f"Sources/{module}")
    tree(ROOT / "Packages/SourceCapture/Sources/SourceCapture", "Sources/SourceCapture")
    copy(sources("WorkWiki", "Runtime"), "Sources/WorkWiki")
    copy([ROOT / "Packages/ASKApplication/Sources/ASKApplication/Application" / name for name in [
        "ASKApplicationConfiguration.swift", "ASKApplicationMutation.swift"]], "Sources/ASKApplication")
    copy([ROOT / "Sources/ASK" / name for name in [
        "PublicTypes.swift", "ASKTypedContracts.swift", "ASKDiagnostic.swift", "ASKErrorMapping.swift",
        "ASKPlanning.swift", "ASKCommandExecutionReducer.swift", "ASKMutationFootprint.swift",
        "ASKManagedRouteContainment.swift", "ASKPresentationRepairTokenFactory.swift"]], "Sources/ASK")
    copy([ROOT / "Packages/PageIndex/Tests/PageIndexTests" / name for name in [
        "CurrentSourceSchemaTests.swift", "SourceIndexReconciliationTests.swift", "SourceIndexTransactionTests.swift"]], "Tests/PageIndexTests")
    copy([ROOT / "Packages/WorkWiki/Tests/WorkWikiTests/WorkWikiRevisionWorkflowTests.swift"], "Tests/WorkWikiTests")
    copy([ROOT / "Packages/ASKApplication/Tests/ASKApplicationTests/ASKMutationResourceTests.swift"], "Tests/ASKApplicationTests")
    copy([ROOT / "Tests/ASKTests/ASKPublicAPITests" / name for name in [
        "ASKDiagnosticMappingTests.swift", "ASKReplayPolicyTests.swift", "ASKMutationFootprintTests.swift", "ASKGroundedEvidenceContractTests.swift"]], "Tests/ASKTests")
    tree(ROOT / "Packages/SourceCapture/Tests/SourceCaptureTests", "Tests/SourceCaptureTests")
    copy([ROOT / "Packages/EvidenceIndex/Tests/EvidenceIndexTests/ExactEvidenceTests.swift"], "Tests/EvidenceIndexTests")
    copy([ROOT / "Verification/OwnerChecks/IndexDriver.swift"], "Sources/IndexDriver")
    manifest = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "OwnerChecks", platforms: [.iOS(.v17), .macOS(.v15)], dependencies: [
  .package(path: CORE), .package(path: RUNTIME)
], targets: [
  .target(name: "PageIndex", dependencies: [.product(name: "KnowledgeCore", package: "KnowledgeCore")], resources: [.process("Resources")]),
  .target(name: "EvidenceIndex", dependencies: ["PageIndex"]),
  .target(name: "HTMLDocument"),
  .target(name: "SourceCapture", dependencies: ["HTMLDocument", .product(name: "KnowledgeCore", package: "KnowledgeCore"), .product(name: "KnowledgeRuntime", package: "KnowledgeRuntime")]),
  .target(name: "WorkWiki", dependencies: ["EvidenceIndex", "PageIndex", .product(name: "KnowledgeCore", package: "KnowledgeCore"), .product(name: "KnowledgeRuntime", package: "KnowledgeRuntime"), .product(name: "DecisionMemory", package: "KnowledgeRuntime")]),
  .target(name: "ASKApplication"),
  .target(name: "ASK", dependencies: ["ASKApplication", "WorkWiki", "PageIndex", "EvidenceIndex", .product(name: "KnowledgeCore", package: "KnowledgeCore")]),
  .testTarget(name: "EvidenceIndexTests", dependencies: ["EvidenceIndex", "PageIndex"]),
  .testTarget(name: "PageIndexTests", dependencies: ["PageIndex"]),
  .testTarget(name: "WorkWikiTests", dependencies: ["WorkWiki", "PageIndex", "EvidenceIndex", .product(name: "KnowledgeRuntime", package: "KnowledgeRuntime")]),
  .testTarget(name: "ASKApplicationTests", dependencies: ["ASKApplication"]),
  .testTarget(name: "ASKTests", dependencies: ["ASK", "WorkWiki", "PageIndex", "EvidenceIndex", .product(name: "KnowledgeCore", package: "KnowledgeCore")]),
  .testTarget(name: "SourceCaptureTests", dependencies: ["SourceCapture", .product(name: "KnowledgeCore", package: "KnowledgeCore"), .product(name: "KnowledgeRuntime", package: "KnowledgeRuntime")], exclude: ["ASKWebCoreTests/Resources"]),
  .executableTarget(name: "IndexDriver", dependencies: ["PageIndex"])
], swiftLanguageModes: [.v6])
'''
    manifest = manifest.replace("CORE", json.dumps(str(ROOT / "Packages/KnowledgeCore"))).replace("RUNTIME", json.dumps(str(ROOT / "Packages/KnowledgeRuntime")))
    (output / "Package.swift").write_text(manifest)
    (output / "source-hashes.json").write_text(json.dumps(copied, indent=2, sort_keys=True) + "\n")
    print(f"Prepared {len(copied)} exact source/fixture files at {output}. Root product and Apple/MCP providers are NOT covered.")

if __name__ == "__main__":
    main()
