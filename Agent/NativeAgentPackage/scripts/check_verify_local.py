#!/usr/bin/env python3
"""Actual harmless-process startup/save-failure regression for verify_local.py.
Usage: check_verify_local.py <helper> <new evidence directory> [--expect-defect]
All injected faults are in this test driver, never in the helper or SDK.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

RUNNER = r'''
import json, os, pathlib, runpy, signal, subprocess, sys
helper, root, fault = sys.argv[1:]
root = pathlib.Path(root)
original_popen = subprocess.Popen
original_write = pathlib.Path.write_text
def popen(*args, **kwargs):
    child = original_popen(*args, **kwargs)
    if 'import time; time.sleep(30)' in args[0]:
        identity = subprocess.run(['ps','-p',str(child.pid),'-o','lstart='],capture_output=True,text=True,timeout=2,check=True).stdout.strip()
        original_write(root/'child.json',json.dumps({'pid':child.pid,'pgid':child.pid,'start':identity}))
        if fault == 'startup-signal': os.kill(os.getpid(), signal.SIGTERM)
    return child
def write(self, text, *args, **kwargs):
    if fault == 'record-failure' and self.name.endswith('.custody.json') and '"pid"' in text:
        raise OSError('injected post-spawn record failure')
    return original_write(self, text, *args, **kwargs)
subprocess.Popen = popen
pathlib.Path.write_text = write
sys.argv = [helper,'--evidence',str(root),'--label','injected','--timeout','1','--',sys.executable,'-c','import time; time.sleep(30)']
runpy.run_path(helper,run_name='__main__')
'''


def exists(group):
    try:
        os.killpg(group, 0)
        return True
    except ProcessLookupError:
        return False


def main():
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)
    helper = Path(sys.argv[1]).resolve(strict=True)
    root = Path(sys.argv[2]).resolve()
    root.mkdir(parents=True, exist_ok=False)
    runner = root / 'fault_runner.py'
    runner.write_text(RUNNER)
    results = []
    for fault in ['startup-signal', 'record-failure']:
        case = root / fault
        case.mkdir()
        with (case / 'runner.log').open('x') as log:
            run = subprocess.Popen([sys.executable, str(runner), str(helper), str(case), fault], stdout=log, stderr=subprocess.STDOUT)
            try:
                code = run.wait(timeout=15)
                identity = json.loads((case / 'child.json').read_text())
                group = identity['pgid']
                leaked = exists(group)
                if leaked:
                    # This PID/group was captured before injecting the fault.
                    os.killpg(group, signal.SIGTERM)
                    deadline = time.monotonic() + 3
                    while exists(group) and time.monotonic() < deadline:
                        time.sleep(.02)
                    if exists(group): os.killpg(group, signal.SIGKILL)
                deadline = time.monotonic() + 3
                while exists(group) and time.monotonic() < deadline:
                    time.sleep(.02)
                immediate = exists(group)
                time.sleep(.2)
                delayed = exists(group)
                result = dict(fault=fault, helper_exit_code=code, leaked_before_test_cleanup=leaked,
                              child=identity, immediate_survivors=immediate, delayed_survivors=delayed,
                              helper_reaped=True)
                results.append(result)
                (root / 'results.json').write_text(json.dumps(results, indent=2))
                assert not immediate and not delayed, result
                assert leaked == ('--expect-defect' in sys.argv), result
            finally:
                if run.poll() is None:
                    run.kill()
                    run.wait(timeout=5)
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
