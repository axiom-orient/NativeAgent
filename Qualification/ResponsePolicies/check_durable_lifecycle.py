#!/usr/bin/env python3
"""Actual FoundationModels/AgentManager fresh-process interruption qualification.
Run under verify_local.py. Usage: check_durable_lifecycle.py <executable> <new root>
"""
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import time


def main():
    if len(sys.argv) != 3 or os.environ.get('NATIVEAGENT_LIVE_FOUNDATION') != '1':
        raise SystemExit(__doc__)
    executable = str(Path(sys.argv[1]).resolve(strict=True))
    root = Path(sys.argv[2]).resolve()
    root.mkdir(parents=True, exist_ok=False)
    records = []
    for mode in ['create', 'interrupt', 'reopen']:
        with (root / (mode + '.log')).open('x') as log:
            command = [executable, mode, str(root)]
            child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            record = {'mode': mode, 'command': command, 'pid': child.pid,
                      'monotonic_deadline': time.monotonic() + 90}
            records.append(record)
            try:
                record['leader_start_identity'] = subprocess.run(
                    ['ps', '-p', str(child.pid), '-o', 'lstart='], capture_output=True,
                    text=True, timeout=2, check=True).stdout.strip()
                (root / 'process-custody.json').write_text(json.dumps(records, indent=2))
                if mode == 'interrupt':
                    while not (root / 'delta-ready').exists():
                        if child.poll() is not None or time.monotonic() >= record['monotonic_deadline']:
                            raise RuntimeError('real model delta interruption boundary not observed')
                        time.sleep(.02)
                    child.kill()
                    assert child.wait(timeout=5) == -signal.SIGKILL
                    record['interruption'] = 'SIGKILL after first actual model delta'
                    with sqlite3.connect(f'file:{root / "native-agent.sqlite3"}?mode=ro', uri=True) as db:
                        started = db.execute("SELECT effect_key FROM session_effects WHERE scope='model_invocation' AND status='started'").fetchall()
                        assert len(started) == 1, started
                        stored = [json.loads(row[0]) for row in db.execute('SELECT payload FROM session_messages ORDER BY ordinal')]
                        expected = json.loads((root / 'expected.json').read_text())['messages']
                        assert stored[:len(expected)] == expected
                        state = db.execute('SELECT status,revision FROM sessions').fetchone()
                        assert state[0] == 'running', state
                        (root / 'interrupted-readback.json').write_text(json.dumps({
                            'invocationID': started[0][0], 'status': state[0], 'revision': state[1],
                            'retained_prefix_messages': len(expected), 'stored_messages': len(stored),
                            'prefix_all_json_fields_equal': True}, indent=2))
                else:
                    assert child.wait(timeout=90) == 0, mode
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=5)
                record.update(exit_code=child.returncode, reaped=True)
                (root / 'process-custody.json').write_text(json.dumps(records, indent=2))
    print(json.dumps({'generation': 'observed', 'SIGKILL': 'observed',
                      'fresh_process_readback': 'observed', 'blind_replay': 'blocked',
                      'explicit_retry': 'completed', 'evidence': str(root)}))


if __name__ == '__main__':
    main()
