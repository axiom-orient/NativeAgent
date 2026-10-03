#!/usr/bin/env python3
"""Run the real local SwiftPM contracts and Agent kernel target. No model inference proof."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform
import re
import signal
import subprocess
import tempfile

from apple_package_runner import uses_xcode_ios_runner, xcodebuild_command

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/verification/current'
JOBS = 4
TIMEOUT_SECONDS = 240
CASES = [
    ('model-core', 'test', 'Model/LanguageModelCore', None, 'Core value contracts; no provider I/O'),
    ('model-runtime', 'test', 'Model/LanguageModelRuntime', None, 'Runtime/session/executor contracts with controlled provider fixtures'),
    ('native-language-models', 'test', 'Model/NativeLanguageModels', None, 'Facade projection, not live inference'),
    ('model-hub', 'test', 'Model/ModelHub', None, 'Hub contract tests, not a live download'),
    ('apple-system-contract', 'test', 'Providers/AppleSystemModel', None, 'Common adapter tests; Apple-only tests are conditional and not qualified on Linux'),
    ('native-root-build', 'build', 'Agent/NativeAgentPackage', 'NativeAgent', 'Actual manifest kernel target; NOT the Manager or full package'),
    ('chatgpt-account', 'test', 'Providers/ChatGPT/Account', None, 'Actual account lifecycle; injected credential/authorization ports, no native login proof'),
    ('chatgpt-text', 'test', 'Providers/ChatGPT/Text', None, 'Actual Text + Account composition; controlled transport, no live subscription proof'),
    ('chatgpt-image', 'test', 'Providers/ChatGPT/Image', None, 'Actual Image + Account composition; completion ownership, not pixel/provider quality'),
    ('chatgpt-text-provider', 'build', 'Providers/ChatGPT/TextProvider', None, 'Actual standalone provider binding build; no live inference'),
]

def hashes(package):
    roots = {package, ROOT / 'Model/LanguageModelCore', ROOT / 'Model/LanguageModelRuntime'}
    if package.is_relative_to(ROOT / 'Providers/ChatGPT'):
        roots.update(ROOT / 'Providers/ChatGPT' / name for name in ('Account', 'Text', 'Image'))
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for root in roots for p in sorted(root.rglob('*'))
            if p.is_file() and p.suffix in ('.swift', '.h', '.modulemap')
            and not set(p.parts) & {'.build', '.swiftpm', '.git'}
            and (p.name == 'Package.swift' or 'Sources' in p.parts or 'Tests' in p.parts)}

def run(scratch):
    if scratch == ROOT or scratch.is_relative_to(ROOT):
        raise SystemExit('Scratch must be outside the source workspace.')
    scratch.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)
    results = []
    for name, verb, relative, target, scope in CASES:
        package = ROOT / relative
        if uses_xcode_ios_runner():
            command = xcodebuild_command(package, verb, scratch / name)
        else:
            command = ['swift', verb, '--package-path', str(package), '--scratch-path',
                       str(scratch / name), '-j', str(JOBS), '-Xswiftc', '-warnings-as-errors']
            if target:
                command += ['--target', target]
        source_hashes = hashes(ROOT / relative)
        with (OUT / (name + '.log')).open('w') as log:
            with subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True) as process:
                try:
                    code = process.wait(timeout=TIMEOUT_SECONDS)
                except (subprocess.TimeoutExpired, KeyboardInterrupt):
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                    code = 124
                    log.write('\nInterrupted/timed out: owned compiler group was terminated.\n')
        text = (OUT / (name + '.log')).read_text()
        tests = re.findall(r'Test run with (\d+) tests? .*passed', text)
        entry = {'name': name, 'status': 'PASS' if code == 0 else 'FAIL', 'exitCode': code,
                 'command': command, 'scope': scope, 'swiftTestingCount': int(tests[-1]) if tests else None,
                 'sourceHashes': source_hashes}
        results.append(entry)
        print(name, entry['status'], entry['swiftTestingCount'], flush=True)
    result = {'status': 'PASS' if all(r['exitCode'] == 0 for r in results) else 'FAIL',
              'platform': platform.platform(),
              'swift': subprocess.run(['swift', '--version'], capture_output=True, text=True, check=True).stdout.strip(),
              'results': results,
              'limits': ['No native SDK/Metal/device/account or actual model inference proof.',
                         'ASK and artifact-store platform gates are separate; this is not a full workspace build.',
                         'A conditional branch excluded by the compiler is not a passing native test.',
                         'On macOS, package tests use the discovered iOS Simulator destination; no macOS product target is qualified.']}
    (OUT / 'portable.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    return 0 if result['status'] == 'PASS' else 1

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scratch', type=Path, help='Optional persistent build cache outside this workspace')
    args = parser.parse_args()
    if args.scratch:
        raise SystemExit(run(args.scratch.resolve()))
    with tempfile.TemporaryDirectory(prefix='nativeai-portable-') as directory:
        raise SystemExit(run(Path(directory)))
