#!/usr/bin/env python3
"""Run one bounded local verification command with private logs and process custody.

Example: python3 scripts/verify_local.py --evidence /tmp/nativeagent-proof --label core -- swift test --package-path .
Use explicit environment opt-ins documented in docs/MACOS_MAINTENANCE.md for live tests.
This is a local verification helper, not release automation or CI.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--label', required=True)
    parser.add_argument('--timeout', type=float, default=600)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or not args.label.replace('-', '').replace('_', '').isalnum() or not 0 < args.timeout <= 3600:
        parser.error('command, safe label and timeout in (0,3600] required')
    root = args.evidence.resolve()
    workspace = Path(__file__).resolve().parents[1]
    if root == workspace or workspace in root.parents:
        parser.error('evidence must be outside the source workspace')
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    log_path = root / (args.label + '.log')
    record_path = root / (args.label + '.custody.json')
    if log_path.exists() or record_path.exists():
        parser.error('label already used; preserve earlier evidence and choose a new label')
    started = time.monotonic()
    record = dict(command=command, cwd=str(workspace), start=time.time(), timeout=args.timeout,
                  operation_id=str(uuid.uuid4()), supervisor_pid=os.getpid(),
                  monotonic_start=started, monotonic_deadline=started + args.timeout,
                  teardown_seconds=10, scope='new POSIX process group',
                  limitation='No containment for deliberate setsid/daemon escape or supervisor SIGKILL')
    def save():
        record_path.write_text(json.dumps(record, indent=2) + '\n')
        record_path.chmod(0o600)
    save()
    cancelled = False
    def terminate(_signum, _frame):
        # Never raise between successful spawn and assignment of the child handle.
        nonlocal cancelled
        cancelled = True
    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    with log_path.open('x') as log:
        log_path.chmod(0o600)
        if cancelled:
            record.update(cancelled_before_launch=True, helper_exit_code=124, reaped=True,
                          immediate_survivors=False, delayed_survivors=False)
            save()
            return 124
        try:
            child = subprocess.Popen(command, cwd=workspace, stdout=log, stderr=subprocess.STDOUT,
                                     start_new_session=True)
        except OSError as error:
            record.update(launch_failed=type(error).__name__, child_exit_code=None, helper_exit_code=127, reaped=True, survivors=False, end=time.time())
            save()
            return 127
        group = child.pid  # captured immediately from start_new_session contract; never reconstructed
        identity = ''
        def exists():
            try:
                os.killpg(group, 0)
                return True
            except ProcessLookupError:
                return False
            except OSError as error:
                record.setdefault('probe_errors', []).append(type(error).__name__)
                return None  # unknown is never proof of no survivor
        code = 125
        try:
            record.update(pid=child.pid, pgid=group)
            # The unreaped leader retains its PID even when it exits during this read.
            identity = subprocess.run(['ps', '-p', str(child.pid), '-o', 'lstart='],
                                      capture_output=True, text=True, timeout=2, check=True).stdout.strip()
            record['leader_start_identity'] = identity
            save()
            code = 124
            while not cancelled and time.monotonic() < record['monotonic_deadline']:
                try:
                    code = child.wait(timeout=min(.1, max(0, record['monotonic_deadline'] - time.monotonic())))
                    break
                except subprocess.TimeoutExpired:
                    continue
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            code = 124
        except BaseException as error:
            record['custody_error'] = type(error).__name__
            code = 125
        finally:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            actions = []
            record['teardown_monotonic_start'] = time.monotonic()
            record['teardown_monotonic_deadline'] = record['teardown_monotonic_start'] + 10
            def send(signum):
                try:
                    os.killpg(group, signum)
                    actions.append(signal.Signals(signum).name + ' owned group')
                except ProcessLookupError:
                    actions.append('group exited before signal')
                except OSError as error:
                    actions.append('signal failed: ' + type(error).__name__)
            if exists() is not False:
                send(signal.SIGTERM)
                deadline = record['teardown_monotonic_start'] + 4
                while exists() is not False and time.monotonic() < deadline:
                    child.poll()  # reap the leader while observing descendants
                    time.sleep(0.05)
                if exists() is not False:
                    send(signal.SIGKILL)
            try:
                child.wait(timeout=max(.1, record['teardown_monotonic_deadline'] - time.monotonic() - .3))
                reaped = True
            except subprocess.TimeoutExpired:
                reaped = False
            immediate = exists()
            time.sleep(0.2)
            delayed = exists()
            helper_code = code if identity and reaped and immediate is False and delayed is False else 125
            record.update(child_exit_code=child.returncode, exit_code=code, helper_exit_code=helper_code,
                          cancelled=cancelled,
                          reaped=reaped, immediate_survivors=immediate,
                          delayed_survivors=delayed, teardown=actions, end=time.time())
    record['output_handle_closed'] = log.closed
    try:
        save()
    except OSError as error:
        helper_code = 125
        record.update(helper_exit_code=helper_code, record_write_error=str(error))
        print(json.dumps(record))  # Preserve cleanup proof when the record destination failed.
    print(json.dumps(dict(label=args.label, child_exit_code=child.returncode, helper_exit_code=helper_code, reaped=reaped,
                          survivors=delayed, evidence=str(record_path))))
    return helper_code


if __name__ == '__main__':
    raise SystemExit(main())
