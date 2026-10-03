#!/usr/bin/env python3
"""Exact-source qualification excluding only the NaturalLanguage Manager target.
No production files or manifests are changed. Not a full package/Apple build.
"""
from pathlib import Path
import hashlib, json, os, re, shutil, signal, subprocess, tempfile

from apple_package_runner import uses_xcode_ios_runner, xcodebuild_command
ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'Agent/NativeAgentPackage'
OUT=ROOT/'docs/verification/current'; OUT.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix='native-kernel-qualification-') as temporary:
    work=Path(temporary); hashes={}
    for group,excluded in [('Sources','NativeAgentManager'),('Tests','NativeAgentManagerTests')]:
        for source in (SOURCE/group).rglob('*'):
            if not source.is_file() or excluded in source.relative_to(SOURCE/group).parts or source.name=='.DS_Store': continue
            relative=source.relative_to(SOURCE)
            destination=work/relative; destination.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(source,destination)
            hashes[str(source.relative_to(ROOT))]=hashlib.sha256(source.read_bytes()).hexdigest()
    # Hash the exact local contract/runtime inputs, not only the copied Agent files.
    for name in ('LanguageModelCore', 'LanguageModelRuntime'):
        dependency = ROOT/'Model'/name
        for source in [dependency/'Package.swift', *sorted((dependency/'Sources').rglob('*.swift'))]:
            hashes[str(source.relative_to(ROOT))] = hashlib.sha256(source.read_bytes()).hexdigest()
    manifest=(SOURCE/'Package.swift').read_text()
    manifest=manifest.replace('  "NativeAgentManager",\n','',1)
    for kind,name in [('target','NativeAgentManager'),('testTarget','NativeAgentManagerTests')]:
        pattern=rf'    \.{kind}\(\s*name: "{name}"'
        match=re.search(pattern,manifest)
        if not match: raise RuntimeError(f'Manifest changed; cannot locate {name}')
        start=match.start(); opening=manifest.index('(',start); depth=0; end=None
        for i in range(opening,len(manifest)):
            if manifest[i]=='(': depth+=1
            elif manifest[i]==')':
                depth-=1
                if depth==0: end=i+1; break
        if end is None: raise RuntimeError('Unbalanced manifest')
        if manifest[end]==',': end+=1
        manifest=manifest[:start]+manifest[end:]
    for dependency in ('LanguageModelCore','LanguageModelRuntime'):
        manifest=manifest.replace(f'path: "../../Model/{dependency}"', 'path: '+json.dumps(str(ROOT/'Model'/dependency)))
    (work/'Package.swift').write_text(manifest)
    with (OUT/'native-kernel.log').open('w') as log:
        if uses_xcode_ios_runner():
            command=xcodebuild_command(work, 'test', work/'.derived-data')
        else:
            command=['swift','test','--package-path',str(work),'-j','4','-Xswiftc','-warnings-as-errors']
        with subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True) as process:
            try:
                returncode=process.wait(timeout=240)
            except (subprocess.TimeoutExpired, KeyboardInterrupt):
                # Own the whole compiler process group, not only the SwiftPM parent.
                os.killpg(process.pid, signal.SIGTERM)
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                returncode=124
                log.write('\nQualification interrupted or timed out; process group terminated.\n')
    (OUT/'native-kernel.json').write_text(json.dumps({
      'status':'PASS' if returncode==0 else 'FAIL',
      'exitCode':returncode,
      'command':command,
      'sourceHashes':hashes,
      'excluded':['NativeAgentManager','NativeAgentManagerTests','Apple-only conditional branches','actual providers/OS permissions/consumer UI'],
      'note':'Generated qualification manifest only; byte-identical selected source. On macOS the test runs on the discovered iOS Simulator. Model test fixtures are not evidence of live model inference.'
    },ensure_ascii=False,indent=2)+'\n')
    print('PASS' if returncode==0 else 'FAIL')
    raise SystemExit(returncode)
