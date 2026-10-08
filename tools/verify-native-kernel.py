#!/usr/bin/env python3
"""Exact-source qualification excluding only the NaturalLanguage Manager target.
No production files or manifests are changed. Not a full package/Apple build.
"""
from pathlib import Path
import argparse, hashlib, json, os, platform, re, shutil, subprocess, tempfile

from apple_package_runner import run_package_command, uses_xcode_ios_runner, xcodebuild_command
ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'Agent/NativeAgentPackage'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host', action='store_true', help='Explicit SwiftPM host contract qualification, not an iOS/native-provider gate.')
parser.add_argument('--filter', help='Run only the selected SwiftPM test identifiers (requires --host).')
parser.add_argument('--output', type=Path, default=Path(os.environ.get('NATIVEAI_VERIFICATION_OUTPUT', ROOT/'docs/verification/current')))
args = parser.parse_args()
if args.filter and not args.host:
    parser.error('--filter requires --host')
OUT=args.output.resolve(); OUT.mkdir(parents=True, exist_ok=True)

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
    if args.host:
        manifest = manifest.replace('.macOS(.v14)', '.macOS(.v26)')
    (work/'Package.swift').write_text(manifest)
    with (OUT/'native-kernel.log').open('w') as log:
        if uses_xcode_ios_runner() and not args.host:
            command=xcodebuild_command(work, 'test', work/'.derived-data')
        else:
            command=['swift','test','--package-path',str(work),'-j','4','-Xswiftc','-warnings-as-errors']
            if platform.system() == 'Darwin':
                # The root distribution supports macOS 26. Keep this generated
                # host qualification floor out of the iOS-only leaf manifest.
                machine = platform.machine()
                command += ['-Xswiftc','-target','-Xswiftc',f'{machine}-apple-macosx26.0']
            if args.filter:
                command += ['--filter', args.filter]
        returncode = run_package_command(
            command, work, log, timeout=600 if uses_xcode_ios_runner() and not args.host else 240)
    sqlite_diagnostics = [
        line for line in (OUT/'native-kernel.log').read_text().splitlines()
        if 'BUG IN CLIENT OF libsqlite3.dylib:' in line and 'vnode unlinked while in use' in line
    ]
    verification_code = returncode if returncode != 0 else (1 if sqlite_diagnostics else 0)
    (OUT/'native-kernel.json').write_text(json.dumps({
      'status':'PASS' if verification_code==0 else 'FAIL',
      'exitCode':returncode,
      'verificationExitCode':verification_code,
      'sqliteUnlinkDiagnostics':sqlite_diagnostics,
      'command':command,
      'cwd':str(work),
      'sourceHashes':hashes,
      'runner':'host-contracts' if args.host else ('ios-simulator' if uses_xcode_ios_runner() else 'host-contracts'),
      'testFilter':args.filter,
      'excluded':['NativeAgentManager','NativeAgentManagerTests','actual providers/OS permissions/consumer UI'] + (['iOS-only conditional branches'] if args.host or not uses_xcode_ios_runner() else []),
      'note':'Generated qualification manifest only; byte-identical selected source. Explicit --host validates host contracts only. The default macOS path targets an iOS Simulator. Model test fixtures are not evidence of live model inference.'
    },ensure_ascii=False,indent=2)+'\n')
    print('PASS' if verification_code==0 else 'FAIL')
    raise SystemExit(verification_code)
