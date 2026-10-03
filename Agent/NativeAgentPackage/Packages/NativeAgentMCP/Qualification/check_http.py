#!/usr/bin/env python3
"""Run the independent loopback HTTP auth peer under verify_local.py custody.
Usage: check_http.py <node> <http.mjs> <AuthProbe> <new evidence directory>
"""
import json
from pathlib import Path
import subprocess
import sys
import time


def main():
    if len(sys.argv) != 5:
        raise SystemExit(__doc__)
    node, script, probe = [str(Path(p).resolve(strict=True)) for p in sys.argv[1:4]]
    root = Path(sys.argv[4]).resolve()
    root.mkdir(parents=True, exist_ok=False)
    with (root / 'server.log').open('x') as log:
        server = subprocess.Popen([node, script, str(root)], stdout=log, stderr=subprocess.STDOUT)
        record = {'pid': server.pid, 'command': [node, script, str(root)],
                  'monotonic_deadline': time.monotonic() + 30}
        try:
            record['leader_start_identity'] = subprocess.run(
                ['ps', '-p', str(server.pid), '-o', 'lstart='], capture_output=True,
                text=True, check=True, timeout=2).stdout.strip()
            (root / 'server-custody.json').write_text(json.dumps(record, indent=2))
            deadline = time.monotonic() + 10
            while not (root / 'port').exists():
                if server.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError('HTTP peer did not become ready')
                time.sleep(.02)
            endpoint = 'http://127.0.0.1:' + (root / 'port').read_text() + '/mcp'
            subprocess.run([probe, endpoint], check=True, timeout=20)
            requests = (root / 'requests.log').read_text().splitlines()
            assert requests.count('invalid') == 2 and requests.count('valid') >= 1, requests
            print(json.dumps({'invalid_requests': 2, 'valid_requests': requests.count('valid')}))
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)
            record.update(exit_code=server.returncode, reaped=True)
            (root / 'server-custody.json').write_text(json.dumps(record, indent=2))


if __name__ == '__main__':
    main()
