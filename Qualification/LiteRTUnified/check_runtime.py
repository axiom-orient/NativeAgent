#!/usr/bin/env python3
"""Read-only qualification of the shared native release; never updates or publishes."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / 'Providers/LiteRTNative'
FRONTENDS = {'text': ROOT / 'Providers/LiteRT', 'embedding': ROOT / 'Providers/LiteRTEmbedding'}
NAMES = ('CLiteRTLM', 'CLiteRTLM_mac')


def dump(path):
    return json.loads(subprocess.check_output(['swift', 'package', '--package-path', str(path), 'dump-package'], text=True))


def binary_targets(manifest):
    return {t['name']: t for t in manifest['targets'] if t['type'] == 'binary' and t['name'] in NAMES}


def validate(manifests, version):
    errors = []
    owner = binary_targets(manifests['native'])
    root = binary_targets(manifests['root'])
    if set(owner) != set(NAMES) or set(root) != set(NAMES):
        errors.append('Root and shared native package must each declare the two Apple artifacts.')
    for name in NAMES:
        declaration = owner.get(name, {})
        expected = f'https://github.com/google-ai-edge/LiteRT-LM/releases/download/v{version}/{name}.xcframework.zip'
        if declaration.get('url') != expected:
            errors.append(f'{name}: source runtime version and release URL disagree.')
        if not re.fullmatch('[0-9a-f]{64}', declaration.get('checksum', '')):
            errors.append(f'{name}: invalid checksum.')
        if any(root.get(name, {}).get(k) != declaration.get(k) for k in ('url', 'checksum')):
            errors.append(f'{name}: flattened root differs from shared binary owner.')
    for label in ('text', 'embedding'):
        frontend = manifests[label]
        if binary_targets(frontend):
            errors.append(f'{label}: frontend must not redeclare native binaries.')
        target = next(t for t in frontend['targets'] if t['name'] == ('LiteRTProvider' if label == 'text' else 'LiteRTEmbeddingProvider'))
        products = {edge['product'][0:2][0]: edge['product'][1] for edge in target['dependencies'] if 'product' in edge}
        for name in ('LiteRTNative', *NAMES):
            if products.get(name) != 'LiteRTNative':
                errors.append(f'{label}: {name} must come from the shared native package.')
    for label, name in [('text', 'LiteRTProvider'), ('embedding', 'LiteRTEmbeddingProvider')]:
        leaf = next(t for t in manifests[label]['targets'] if t['name'] == name)
        flat = next(t for t in manifests['root']['targets'] if t['name'] == name)
        def names(target):
            return {next(iter(edge.values()))[0] for edge in target['dependencies']}
        if names(flat) != names(leaf) or flat.get('settings', []) != leaf.get('settings', []):
            errors.append(f'{label}: root dependencies/settings differ from the source owner.')
    return errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--official-release-json', type=Path)
    parser.add_argument('--check-latest', action='store_true')
    args = parser.parse_args()
    source = (NATIVE / 'Sources/LiteRTNative/LiteRTNativeRuntime.swift').read_text()
    version = re.search(r'public static let version = "([0-9]+\.[0-9]+\.[0-9]+)"', source).group(1)
    manifests = {'root': dump(ROOT), 'native': dump(NATIVE), **{k: dump(p) for k, p in FRONTENDS.items()}}
    errors = validate(manifests, version)
    release = None
    if args.official_release_json:
        release = json.loads(args.official_release_json.read_text())
    if args.check_latest:
        with urllib.request.urlopen('https://api.github.com/repos/google-ai-edge/LiteRT-LM/releases/latest') as response:
            release = json.load(response)
    if release:
        if release['tag_name'] != 'v' + version:
            errors.append('New official release is not yet qualified; do not claim support or silently float the binary.')
        assets = {a['name']: a for a in release['assets']}
        for name, target in binary_targets(manifests['native']).items():
            if assets.get(name + '.xcframework.zip', {}).get('digest') != 'sha256:' + target['checksum']:
                errors.append(f'{name}: checksum differs from the official release digest.')
    result = {'status': 'FAIL' if errors else 'PASS', 'qualifiedVersion': version, 'errors': errors,
              'scope': 'manifest/release identity only; native inference requires the companion consumer'}
    print(json.dumps(result, indent=2))
    return 1 if errors else 0


if __name__ == '__main__':
    raise SystemExit(main())
