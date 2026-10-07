import copy
import unittest
from check_runtime import dump, validate, ROOT, NATIVE, FRONTENDS

class NativeIdentityRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifests = {'root': dump(ROOT), 'native': dump(NATIVE), **{k: dump(p) for k, p in FRONTENDS.items()}}

    def test_actual_shared_graph(self):
        self.assertEqual(validate(self.manifests, '0.18.0'), [])

    def test_rejects_stale_root_checksum(self):
        value = copy.deepcopy(self.manifests)
        next(t for t in value['root']['targets'] if t['name'] == 'CLiteRTLM')['checksum'] = '0' * 64
        self.assertTrue(validate(value, '0.18.0'))

    def test_rejects_duplicate_frontend_binary(self):
        value = copy.deepcopy(self.manifests)
        value['text']['targets'].append(copy.deepcopy(next(t for t in value['native']['targets'] if t['name'] == 'CLiteRTLM')))
        self.assertTrue(validate(value, '0.18.0'))

    def test_rejects_unqualified_future_release(self):
        self.assertTrue(validate(self.manifests, '0.19.0'))

    def test_rejects_private_frontend_native_owner(self):
        value = copy.deepcopy(self.manifests)
        target = next(t for t in value['embedding']['targets'] if t['name'] == 'LiteRTEmbeddingProvider')
        target['dependencies'] = [edge for edge in target['dependencies'] if edge.get('product', [''])[0] != 'CLiteRTLM']
        self.assertTrue(validate(value, '0.18.0'))

    def test_rejects_root_provider_settings_loss(self):
        value = copy.deepcopy(self.manifests)
        next(t for t in value['root']['targets'] if t['name'] == 'LiteRTProvider')['settings'] = []
        self.assertTrue(validate(value, '0.18.0'))

    def test_rejects_root_provider_dependency_loss(self):
        value = copy.deepcopy(self.manifests)
        target = next(t for t in value['root']['targets'] if t['name'] == 'LiteRTEmbeddingProvider')
        target['dependencies'] = []
        self.assertTrue(validate(value, '0.18.0'))

if __name__ == '__main__':
    unittest.main()
