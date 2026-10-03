#!/usr/bin/env python3
"""Export selected Swift packages and only their local dependency closure.
Manifests, pins, resources, license files and relative paths are not rewritten.
This packages source; it does not resolve remote dependencies or certify a release.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import stat
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = {'.git', '.build', '.swiftpm', '__pycache__', '.DS_Store'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def inside(root, path):
    path = Path(os.path.abspath(path))
    if not path.is_relative_to(root):
        raise ValueError(f'Path escapes source workspace: {path}')
    for parent in [path, *path.parents]:
        if parent == root:
            break
        if parent.is_symlink():
            raise ValueError(f'Symlink is not a relocatable source contract: {parent}')
    return path


def dump_package(package):
    command = ['swift', 'package', '--package-path', str(package), 'dump-package']
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise ValueError(f'Manifest evaluation failed: {package}\n{result.stderr}')
    return json.loads(result.stdout)


def package_closure(root, entries, load=dump_package):
    root = root.resolve()
    pending = [inside(root, root / entry) for entry in entries]
    packages = {}
    while pending:
        package = pending.pop()
        relative = package.relative_to(root).as_posix()
        if relative in packages:
            continue
        manifest = package / 'Package.swift'
        inside(root, manifest)
        before = manifest.read_bytes()
        description = load(package)
        if before != manifest.read_bytes():
            raise ValueError(f'Manifest changed while evaluating: {relative}')
        local, remote = [], []
        for dependency in description['dependencies']:
            if 'fileSystem' in dependency:
                for record in dependency['fileSystem']:
                    dependency_path = inside(root, record['path'])
                    local.append(dependency_path.relative_to(root).as_posix())
                    pending.append(dependency_path)
            else:
                remote.append(dependency)
        for target in description['targets']:
            if target.get('path'):
                target_path = inside(root, package / target['path'])
                if not target_path.is_relative_to(package):
                    raise ValueError(f'External target path needs an explicit package boundary: {relative}')
        packages[relative] = {
            'name': description['name'], 'manifestSHA256': digest(before),
            'products': [product['name'] for product in description['products']],
            'localDependencies': sorted(local), 'remoteDependencies': remote,
        }
    return dict(sorted(packages.items()))


def snapshot(root, packages):
    files = {}
    for relative in packages:
        package = root / relative
        for directory, directories, names in os.walk(package, followlinks=False):
            directory = Path(directory)
            # Nested packages are collected only by their own selected closure entry.
            for name in list(directories):
                child = directory / name
                if name in EXCLUDED:
                    directories.remove(name)
                elif child.is_symlink():
                    raise ValueError(f'Symlink directory: {child}')
                elif (child / 'Package.swift').is_file():
                    directories.remove(name)
            for name in names:
                if name in EXCLUDED or name.endswith('.pyc'):
                    continue
                path = inside(root, directory / name)
                mode = path.stat().st_mode
                if not stat.S_ISREG(mode):
                    raise ValueError(f'Not a regular source file: {path}')
                files[path.relative_to(root).as_posix()] = (
                    path.read_bytes(), 0o755 if mode & 0o111 else 0o644)
        if digest(files[f'{relative}/Package.swift'][0]) != packages[relative]['manifestSHA256']:
            raise ValueError(f'Manifest changed while collecting sources: {relative}')
    # Preserve workspace license/notice obligations, without the umbrella docs/integrations.
    for path in root.iterdir():
        if path.name.upper().startswith(('LICENSE', 'NOTICE')) and path.is_file():
            inside(root, path)
            files[path.name] = (path.read_bytes(), 0o644)
    return dict(sorted(files.items()))


def export(root, entries, output, load=dump_package):
    root = root.resolve()
    output = output.resolve()
    if output.is_relative_to(root):
        raise ValueError('Output must be outside the source workspace.')
    if output.exists():
        raise FileExistsError(f'Refusing to overwrite: {output}')
    packages = package_closure(root, entries, load)
    files = snapshot(root, packages)
    evidence = {
        'schema': 'nativeai.source-bundle/1',
        'entries': sorted(set(entries)), 'packages': packages,
        'files': {name: {'sha256': digest(data), 'mode': oct(mode)} for name, (data, mode) in files.items()},
        'verification': 'Source closure only; no remote resolution, Apple build or live-service claim.',
    }
    files['BUNDLE.json'] = ((json.dumps(evidence, indent=2, ensure_ascii=False) + '\n').encode(), 0o644)
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix='.nativeai-bundle-', dir=output.parent)
    os.close(descriptor)
    try:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for name, (data, mode) in sorted(files.items()):
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | mode) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, data)
        # Atomic publication without overwriting an existing artifact, even on a race.
        os.link(temporary, output)
    finally:
        os.unlink(temporary)
    return {'output': str(output), 'sha256': digest(output.read_bytes()),
            'packageCount': len(packages), 'fileCount': len(files), 'entries': sorted(set(entries))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--entry', action='append', required=True, help='Workspace-relative package path; repeat for composition')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(export(ROOT, args.entry, args.output), ensure_ascii=False, indent=2))
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
