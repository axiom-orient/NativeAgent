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


class DistributionManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = dump(ROOT)
        cls.leaves = {
            'MarkdownSyntax': dump(ROOT / 'Knowledge/ASK/Packages/DocumentCore'),
            'LEAPProvider': dump(ROOT / 'Providers/LEAP'),
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


if __name__ == '__main__':
    unittest.main()
