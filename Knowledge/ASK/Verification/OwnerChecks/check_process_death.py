#!/usr/bin/env python3
"""Linux/macOS process-death checks against the real SourceIndexStore driver.
Usage: check_process_death.py <built IndexDriver> <new output directory>
No production fault-injection branches. Requires clang and ELF/dyld interposition.
"""
import hashlib
import json
import os
import resource
import subprocess
import sys
from pathlib import Path


def main():
    if len(sys.argv) != 3 or sys.platform not in ('linux', 'darwin'):
        raise SystemExit(__doc__)
    driver = Path(sys.argv[1]).resolve(strict=True)
    out = Path(sys.argv[2]).resolve()
    out.mkdir(parents=True, exist_ok=False)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    library = out / ('crash.dylib' if sys.platform == 'darwin' else 'crash.so')
    linker = ['-dynamiclib'] if sys.platform == 'darwin' else ['-shared', '-fPIC', '-ldl']
    subprocess.run(['clang', '-Wall', '-Wextra', '-Werror',
                    str(Path(__file__).with_name('crash_after_io.c')), *linker, '-o', str(library)], check=True)
    results = []

    def run(root, operation, text='unused', crash=None):
        env = os.environ.copy()
        if crash:
            env.update(ASK_CRASH_OP=crash[0], ASK_CRASH_SUFFIX=crash[1])
            env['DYLD_INSERT_LIBRARIES' if sys.platform == 'darwin' else 'LD_PRELOAD'] = str(library)
        result = subprocess.run([str(driver), str(root), operation, text], env=env, capture_output=True, text=True, timeout=20)
        return result

    def checked(root, operation, text='unused'):
        p = run(root, operation, text)
        if p.returncode != 0:
            raise RuntimeError(f'{operation}: {p.returncode}\n{p.stderr}')
        return p.stdout

    def snapshot(root):
        return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in root.rglob('*') if p.is_file() and p.name != '.source-index.lock'}

    for phase in ['prepared', 'artifact', 'manifest', 'committed', 'delete-artifact', 'delete-history', 'recovery', 'next-write']:
        root = out / phase
        checked(root, 'put', 'before')
        if phase == 'delete-history':
            checked(root, 'put', 'second-before')
        before = snapshot(root)
        artifact = next((root / 'index/artifacts').glob('*.json')).name
        history = next((root / 'index/history').rglob('*.json')).name if phase == 'delete-history' else ''
        operation = 'delete' if phase.startswith('delete-') else 'put'
        selected = {
            'prepared': ('rename', '.source-index-pending.json'),
            'artifact': ('rename', artifact),
            'manifest': ('rename', '_source_manifest.json'),
            'committed': ('unlink', '.source-index-pending.json'),
            'delete-artifact': ('unlink', artifact),
            'delete-history': ('unlink', history),
            'recovery': ('rename', '_source_manifest.json'),
            'next-write': ('rename', artifact),
        }[phase]
        killed = run(root, operation, 'interrupted', selected)
        (out / f'{phase}.log').write_text(killed.stderr)
        assert killed.returncode == 90, (phase, killed.returncode, killed.stderr)
        pending = root / 'index/.source-index-pending.json'
        if phase == 'committed':
            assert not pending.exists()
            observed = checked(root, 'inspect')
            assert observed.startswith('interrupted\n'), observed
            assert checked(root, 'recover') == 'recovered:false\n'
        else:
            assert pending.exists(), phase
            observed = run(root, 'inspect')
            assert observed.returncode != 0, (phase, observed.stdout)
            if phase == 'next-write':
                assert checked(root, 'put', 'after') == 'published:after\n'
                assert checked(root, 'inspect') == 'after\nhistory:1\n'
                assert not pending.exists()
            else:
                if phase == 'recovery':
                    again = run(root, 'recover', crash=('rename', artifact))
                    assert again.returncode == 90 and pending.exists()
                assert checked(root, 'recover') == 'recovered:true\n'
                assert snapshot(root) == before, phase
                assert checked(root, 'recover') == 'recovered:false\n'
                assert checked(root, 'inspect').startswith('second-before' if phase == 'delete-history' else 'before')
        results.append({'phase': phase, 'injected_exit': 90, 'result': 'PASS'})
    (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results, indent=2))

if __name__ == '__main__':
    main()
