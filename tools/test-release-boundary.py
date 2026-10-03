#!/usr/bin/env python3
"""Regression tests for retained migration-hold release classification, not a current release gate or provider runtime."""
from pathlib import Path
import importlib.util
import sys
import unittest
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
path = ROOT / 'MigrationHold/NativeAgentRelease/scripts/release.py'
spec = importlib.util.spec_from_file_location('nativeai_release', path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
class ReleaseManifestBoundaryTests(unittest.TestCase):
    def audit(self, text):
        failures = []
        name = 'Packages/Boundary/Package.swift'
        module.check_package_manifests({name: text}, {name}, failures)
        return failures
    def binary(self, extra=''):
        return '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Boundary", products: [.library(name: "Foreign", targets: ["Foreign"])], targets: [
.binaryTarget(name: "Foreign", url: "https://example.invalid/Foreign.zip", checksum: "''' + 'a'*64 + '''")''' + extra + '''])'''
    def test_binary_only_has_no_fictional_swift_compilation_requirements(self):
        self.assertEqual(self.audit(self.binary()), [])
    def test_adding_a_source_target_retains_all_strict_swift_guards(self):
        failures = self.audit(self.binary(', .target(name: "Bridge", dependencies: ["Foreign"])'))
        self.assertEqual(len(failures), 4)
        self.assertTrue(any('language mode' in s for s in failures))
        for feature in ('ExistentialAny', 'MemberImportVisibility', 'ImmutableWeakCaptures'):
            self.assertTrue(any(feature in s for s in failures), feature)
    def test_binary_checksum_is_still_required(self):
        text = self.binary().replace(', checksum: "'+'a'*64+'"', '')
        self.assertEqual(self.audit(text), ['remote binary target lacks checksum: Packages/Boundary/Package.swift'])
class RootPackageLayoutTests(unittest.TestCase):
    def root(self, name="NativeAgent", dependencies=""):
        return ("// swift-tools-version: 6.2\nimport PackageDescription\n"
                "let package = Package(name: \"" + name + "\", "
                "dependencies: [" + dependencies + "], targets: [], "
                "swiftLanguageModes: [.v6])\n"
                '// ExistentialAny MemberImportVisibility ImmutableWeakCaptures\n')

    def test_root_package_is_discovered(self):
        text = self.root()
        self.assertEqual(module.package_manifests({"Package.swift": text}), {"NativeAgent": text})

    def test_nested_package_can_depend_on_root(self):
        texts = {
            "Package.swift": self.root(),
            "Packages/Child/Package.swift": self.root("Child", '.package(path: "../..")'),
        }
        failures = []
        module.check_package_manifests(texts, set(texts), failures)
        self.assertEqual(failures, [])

    def test_real_source_root_escape_remains_rejected(self):
        texts = {"Package.swift": self.root(dependencies='.package(path: "../Other")')}
        failures = []
        module.check_package_manifests(texts, set(texts), failures)
        self.assertTrue(any("escapes source root" in value for value in failures))

    def test_root_sources_change_native_surface_identity(self):
        surfaces = {"surfaces": [{"name": "NativeAgent", "packages": ["NativeAgent"]}]}
        before = (module.Entry("Sources/NativeAgent/Agent.swift", b"before", module.digest(b"before"), 0o644),)
        after = (module.Entry("Sources/NativeAgent/Agent.swift", b"after", module.digest(b"after"), 0o644),)
        self.assertNotEqual(module.surface_versions(before, surfaces), module.surface_versions(after, surfaces))

    def test_optional_package_does_not_change_root_surface_identity(self):
        surfaces = {"surfaces": [{"name": "NativeAgent", "packages": ["NativeAgent"]}]}
        optional = (module.Entry("Packages/Optional/Sources/Other.swift", b"new", module.digest(b"new"), 0o644),)
        self.assertEqual(module.surface_versions((), surfaces), module.surface_versions(optional, surfaces))

    def test_root_package_and_agent_instructions_are_archived(self):
        self.assertTrue(module.allowed_top_level(Path("Package.swift")))
        self.assertTrue(module.allowed_top_level(Path("Sources/NativeAgent/Agent.swift")))
        self.assertTrue(module.allowed_top_level(Path("AGENTS.md")))

class AppleOptionalBoundaryTests(unittest.TestCase):
    def check(self, injected_path, text):
        import shutil
        import subprocess
        import tempfile
        with tempfile.TemporaryDirectory(prefix="apple-boundary-guard-") as directory:
            root = Path(directory)
            for relative in ("Sources/AppleLocalAICore", "Sources/AppleLocalAI", "Tests",
                             "Packages/AppleLocalAILocalModels/Sources/AppleLocalAILocalModels",
                             "Packages/AppleLocalAILEAP/Sources/AppleLocalAILEAP",
                             "Packages/NativeAgentProviderAppleLocalAI/Sources", "scripts", "docs"):
                (root/relative).mkdir(parents=True, exist_ok=True)
            (root/"Package.swift").write_text("// package-root fixture for a static guard only\n")
            (root/"README.md").write_text("static guard fixture\n")
            (root/"Packages/NativeAgentProviderAppleLocalAI/Package.swift").write_text("// adapter fixture\n")
            destination = root/injected_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(text)
            shutil.copy2(ROOT/"MigrationHold/AppleLocalAI/scripts/check-architecture.sh", root/"scripts/check-architecture.sh")
            return subprocess.run(["sh", str(root/"scripts/check-architecture.sh")], capture_output=True, text=True)

    def test_only_explicit_optional_adapter_may_import_runtime(self):
        result = self.check("Packages/NativeAgentProviderAppleLocalAI/Sources/Bridge.swift", "import LanguageModelRuntime\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_root_cannot_import_runtime(self):
        result = self.check("Sources/AppleLocalAI/Bad.swift", "import LanguageModelRuntime\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("crossed into AppleLocalAI", result.stderr)

    def test_other_optional_package_is_not_exempted(self):
        result = self.check("Packages/Unexpected/Sources/Bad.swift", "import LanguageModelRuntime\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("only in the explicit optional adapter", result.stderr)

    def test_adapter_cannot_become_root_dependency(self):
        result = self.check("Package.swift", 'let dependency = "NativeAgentProviderAppleLocalAI"\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("root dependency graph", result.stderr)

    def test_adapter_cannot_import_a_second_vendor_loader(self):
        result = self.check("Packages/NativeAgentProviderAppleLocalAI/Sources/Bad.swift", "import MLXProvider\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not own a vendor loader", result.stderr)

if __name__ == '__main__':
    unittest.main()
