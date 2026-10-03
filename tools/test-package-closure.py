#!/usr/bin/env python3
"""Pure exporter boundary tests. A relocated Swift consumer is a separate real-build gate."""
from pathlib import Path
import hashlib
import importlib.util
import json
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('package_closure', Path(__file__).with_name('package-closure.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class PackageClosureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        # SwiftPM emits canonical absolute file-system paths. Match that
        # contract so the fixture remains valid on macOS, where /var may be a
        # symlink to /private/var.
        self.root = (Path(self.temporary.name) / 'source').resolve()
        self.root.mkdir()
        self.descriptions = {}
        self.package('A', ['B'])
        self.package('B')
        self.package('Unrelated')
        self.package('A/Optional')
        self.output = self.root.parent / 'bundle.zip'

    def package(self, name, dependencies=()):
        path = self.root / name
        (path / 'Sources').mkdir(parents=True)
        (path / 'Package.swift').write_text(f'// fixture manifest: {name}\n')
        (path / 'Sources/Source.swift').write_text('// source fixture\n')
        self.descriptions[path] = {'name': name, 'products': [{'name': name}], 'targets': [],
            'dependencies': [{'fileSystem': [{'path': str(self.root / dep)}]} for dep in dependencies]}
        return path

    def export(self, entries=('A',), output=None):
        return module.export(self.root, entries, output or self.output, self.descriptions.__getitem__)

    def test_exports_only_transitive_local_dependencies(self):
        result = self.export()
        self.assertEqual(result['packageCount'], 2)
        with zipfile.ZipFile(self.output) as archive:
            names = archive.namelist()
            self.assertIn('B/Package.swift', names)
            self.assertFalse(any('Optional' in name or 'Unrelated' in name for name in names))
            manifest = json.loads(archive.read('BUNDLE.json'))
            for name, record in manifest['files'].items():
                self.assertEqual(record['sha256'], hashlib.sha256(archive.read(name)).hexdigest())

    def test_deterministic_archive_ignores_entry_order_and_duplicates(self):
        first = self.export(('A', 'B', 'A'))
        second = self.export(('B', 'A'), self.output.with_name('second.zip'))
        self.assertEqual(first['sha256'], second['sha256'])

    def test_selected_nested_package_is_retained(self):
        self.export(('A', 'A/Optional'))
        with zipfile.ZipFile(self.output) as archive:
            self.assertIn('A/Optional/Package.swift', archive.namelist())

    def test_external_dependency_is_rejected_before_publication(self):
        self.descriptions[self.root / 'A']['dependencies'] = [{'fileSystem': [{'path': str(self.root.parent / 'escape')}]}]
        with self.assertRaisesRegex(ValueError, 'escapes'):
            self.export()
        self.assertFalse(self.output.exists())

    def test_symlink_source_is_rejected(self):
        (self.root / 'A/Sources/secret').symlink_to(self.root.parent)
        with self.assertRaisesRegex(ValueError, 'Symlink'):
            self.export()
        self.assertFalse(self.output.exists())

    def test_manifest_change_during_evaluation_is_rejected(self):
        def mutated(path):
            (path / 'Package.swift').write_text('changed')
            return self.descriptions[path]
        with self.assertRaisesRegex(ValueError, 'changed'):
            module.export(self.root, ['A'], self.output, mutated)

    def test_existing_output_is_never_overwritten(self):
        self.output.write_bytes(b'original')
        with self.assertRaises(FileExistsError):
            self.export()
        self.assertEqual(self.output.read_bytes(), b'original')

    def test_source_tree_cannot_be_output(self):
        with self.assertRaisesRegex(ValueError, 'outside'):
            self.export(output=self.root / 'bad.zip')

    def test_cache_is_not_a_source_artifact(self):
        (self.root / 'A/.build').mkdir()
        (self.root / 'A/.build/cache').write_text('cache')
        self.export()
        with zipfile.ZipFile(self.output) as archive:
            self.assertFalse(any('.build' in name for name in archive.namelist()))

if __name__ == '__main__':
    unittest.main()
