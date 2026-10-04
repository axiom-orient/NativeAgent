"""Keep the remote distribution's external target edges aligned with their leaf owners."""
import copy
import json
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]


def dump(path):
    result = subprocess.run(['swift', 'package', '--package-path', str(path), 'dump-package'],
                            check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def external_edges(manifest, target):
    remote = {entry['sourceControl'][0]['identity'].lower(): entry['sourceControl'][0]
              for entry in manifest['dependencies'] if 'sourceControl' in entry}
    node = next(node for node in manifest['targets'] if node['name'] == target)
    return [(edge['product'], remote[edge['product'][1].lower()])
            for edge in node['dependencies']
            if 'product' in edge and edge['product'][1].lower() in remote]


def distribution_errors(root, leaf, target):
    errors = []
    actual = external_edges(root, target)
    for product, declaration in external_edges(leaf, target):
        match = next((package for edge, package in actual if edge == product), None)
        if match is None:
            errors.append(f'{target} is missing external product {product[:2]}')
        elif any(match[key] != declaration[key] for key in ['location', 'requirement']):
            errors.append(f'{target} changes the leaf URL/version for {product[:2]}')
    return errors


def dependency_names(target):
    return {next(iter(edge.values()))[0] for edge in target['dependencies']}


def concrete_product_errors(manifest):
    targets = {target['name'] for target in manifest['targets']}
    return [product['name'] for product in manifest['products']
            if product['targets'] != [product['name']] or product['name'] not in targets]


class DistributionManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = dump(ROOT)
        cls.leaves = {
            'MarkdownSyntax': dump(ROOT / 'Knowledge/ASK/Packages/DocumentCore'),
            'LEAPProvider': dump(ROOT / 'Providers/LEAP'),
        }
        cls.providers = {
            'ChatGPTTextProvider': dump(ROOT / 'Providers/ChatGPT/TextProvider'),
            'AppleSystemModelProvider': dump(ROOT / 'Providers/AppleSystemModel'),
            'ChatGPTImageCapability': dump(ROOT / 'Agent/NativeAgentPackage/Packages/ChatGPTImageCapability'),
        }

    def test_external_edges_preserve_leaf_product_url_and_version(self):
        for target, leaf in self.leaves.items():
            with self.subTest(target=target):
                self.assertTrue(external_edges(leaf, target))
                self.assertEqual(distribution_errors(self.root, leaf, target), [])

    def test_each_missing_edge_is_detected(self):
        for target, leaf in self.leaves.items():
            for product, _ in external_edges(leaf, target):
                with self.subTest(target=target, product=product[0]):
                    mutant = copy.deepcopy(self.root)
                    node = next(node for node in mutant['targets'] if node['name'] == target)
                    node['dependencies'] = [edge for edge in node['dependencies']
                                            if edge.get('product') != product]
                    self.assertTrue(distribution_errors(mutant, leaf, target))

    def test_products_select_concrete_modules_without_composition_targets(self):
        self.assertEqual(concrete_product_errors(self.root), [])
        products = {product['name'] for product in self.root['products']}
        for required in ['NativeAgent', 'NativeAgentDomain', 'LanguageModelCore',
                         'LanguageModelRuntime', 'ChatGPTAccount', 'ChatGPTTextProvider',
                         'ChatGPTImage', 'ChatGPTImageCapability', 'AppleSystemModelProvider']:
            self.assertIn(required, products)
        mutant = copy.deepcopy(self.root)
        mutant['products'][0]['targets'].append('ChatGPTAccount')
        self.assertTrue(concrete_product_errors(mutant))

    def test_provider_edges_settings_and_resources_match_leaf_owners(self):
        for name, leaf in self.providers.items():
            with self.subTest(target=name):
                actual = next(target for target in self.root['targets'] if target['name'] == name)
                expected = next(target for target in leaf['targets'] if target['name'] == name)
                self.assertEqual(dependency_names(actual), dependency_names(expected))
                self.assertEqual(actual.get('settings', []), expected.get('settings', []))
                self.assertEqual(actual.get('resources', []), expected.get('resources', []))
                self.assertTrue((ROOT / actual['path']).is_dir())

    def test_core_and_kernel_preserve_dependency_direction(self):
        for name, forbidden in {
            'LanguageModelCore': {'NativeAgent', 'ChatGPTAccount', 'ChatGPTText', 'ChatGPTImage', 'ASK', 'NativeAgentUI'},
            'NativeAgentDomain': {'ChatGPTAccount', 'ChatGPTText', 'ChatGPTImage', 'ASK', 'NativeAgentUI'},
        }.items():
            target = next(target for target in self.root['targets'] if target['name'] == name)
            self.assertFalse(dependency_names(target) & forbidden)
        self.assertTrue(all('sourceControl' in edge for edge in self.root['dependencies']))


if __name__ == '__main__':
    unittest.main()
