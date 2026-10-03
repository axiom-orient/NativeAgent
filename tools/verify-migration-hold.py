#!/usr/bin/env python3
"""Compile/test exact portable source files. This is NOT an Apple SDK build."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import tempfile

from apple_package_runner import uses_xcode_ios_runner, xcodebuild_command

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/verification/current'
OUT.mkdir(parents=True, exist_ok=True)
APPLE = ROOT / 'MigrationHold/AppleLocalAI'
PACKAGES = ROOT / 'Model'
PROVIDER = ROOT / 'MigrationHold/AppleLocalAI/Packages/NativeAgentProviderAppleLocalAI'
files = []

def copy(source: Path, destination: Path):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    files.append({'source': str(source.relative_to(ROOT)), 'sha256': hashlib.sha256(source.read_bytes()).hexdigest()})

with tempfile.TemporaryDirectory(prefix='native-boundary-qualification-') as directory:
    work = Path(directory)
    for source in (APPLE / 'Sources/AppleLocalAICore').glob('*.swift'):
        copy(source, work / 'Sources/AppleLocalAICore' / source.name)
    copy(APPLE / 'Sources/AppleLocalAI/OperationController.swift', work / 'Sources/AppleLocalAI/OperationController.swift')
    copy(PROVIDER / 'Sources/NativeAgentProviderAppleLocalAI/AppleLocalAITextClient.swift', work / 'Sources/NativeAgentProviderAppleLocalAI/AppleLocalAITextClient.swift')
    copy(PROVIDER / 'Sources/NativeAgentProviderAppleLocalAI/NativeRuntimeBinding.swift', work / 'Sources/NativeAgentProviderAppleLocalAI/NativeRuntimeBinding.swift')
    for source in (APPLE / 'Tests/AppleLocalAICoreTests').glob('*.swift'):
        copy(source, work / 'Tests/AppleLocalAICoreTests' / source.name)
    copy(APPLE / 'Tests/AppleLocalAITests/OperationControllerTests.swift', work / 'Tests/AppleLocalAITests/OperationControllerTests.swift')
    for source in (PROVIDER / 'Tests/NativeAgentProviderAppleLocalAITests').glob('*.swift'):
        copy(source, work / 'Tests/NativeAgentProviderAppleLocalAITests' / source.name)
    manifest = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "PortableBoundaryQualification", platforms: [.iOS(.v17)], dependencies: [
.package(name: "LanguageModelCore", path: CORE),
.package(name: "LanguageModelRuntime", path: RUNTIME)
], targets: [
.target(name: "AppleLocalAICore"),
.target(name: "AppleLocalAI", dependencies: ["AppleLocalAICore"]),
.target(name: "NativeAgentProviderAppleLocalAI", dependencies: [.product(name: "LanguageModelCore", package: "LanguageModelCore"), .product(name: "LanguageModelRuntime", package: "LanguageModelRuntime")]),
.testTarget(name: "AppleLocalAICoreTests", dependencies: ["AppleLocalAICore"]),
.testTarget(name: "AppleLocalAITests", dependencies: ["AppleLocalAI"]),
.testTarget(name: "NativeAgentProviderAppleLocalAITests", dependencies: ["NativeAgentProviderAppleLocalAI", .product(name: "LanguageModelCore", package: "LanguageModelCore"), .product(name: "LanguageModelRuntime", package: "LanguageModelRuntime")])
], swiftLanguageModes: [.v6])
'''.replace('path: CORE', 'path: ' + json.dumps(str(PACKAGES / 'LanguageModelCore'))).replace('path: RUNTIME', 'path: ' + json.dumps(str(PACKAGES / 'LanguageModelRuntime')))
    (work / 'Package.swift').write_text(manifest)
    if uses_xcode_ios_runner():
        command = xcodebuild_command(work, 'test', work/'.derived-data')
    else:
        command = ['swift', 'test', '--package-path', str(work), '-j', '4', '-Xswiftc', '-warnings-as-errors']
    with (OUT / 'migration-hold.log').open('w') as log:
        completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    report = {
        'check': 'exact-source migration-hold regression ONLY; not an active product',
        'status': 'PASS' if completed.returncode == 0 else 'FAIL',
        'exitCode': completed.returncode,
        'command': command,
        'scope': files,
        'excluded': ['AppleLocalAISession.swift, native FoundationModels factory, NativeRuntimeLanguageModel.swift', 'Apple SDK build/link', 'vendor dependency resolution', 'native model inference', 'physical device', 'NativeRuntimeLanguageModelTests: 5 tests guarded by canImport(FoundationModels)'],
        'note': 'On macOS the test runs on the discovered iOS Simulator. Effect closures in provider tests are deterministic test fixtures, not evidence of production model availability or inference.'
    }
    (OUT / 'migration-hold.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'status': report['status'], 'exitCode': completed.returncode, 'log': str(OUT / 'migration-hold.log')}))
    raise SystemExit(completed.returncode)
