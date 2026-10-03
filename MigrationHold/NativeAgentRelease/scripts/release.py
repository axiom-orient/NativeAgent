#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import stat
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any

# Finder/VCS metadata is intentionally invisible to release identity. These paths
# may exist in a checkout but are never archived and never fail verification.
IGNORED_PARTS = {"__MACOSX", ".git"}
IGNORED_NAMES = {".DS_Store", ".gitignore"}

# Generated build/cache state is not source and must be removed before sealing.
FORBIDDEN_PARTS = {
    ".build",
    ".swiftpm",
    "DerivedData",
    "xcuserdata",
    "__pycache__",
    "node_modules",
}
FORBIDDEN_SUFFIXES = {".pyc", ".pyo"}

ALLOWED_TOP_LEVEL_FILES = {"Package.swift", "LICENSE", "README.md", "AGENTS.md"}
ALLOWED_TOP_LEVEL_DIRS = {"Sources", "Tests", "Qualification", "Packages", "docs", "release", "scripts"}
FORBIDDEN_SOURCE_OUTPUTS = {
    "MANIFEST.sha256",
    "SOURCE_TREE.txt",
    "evidence",
}
FIXED_ZIP_TIME = (2026, 9, 4, 0, 0, 0)

SURFACE_NAMES = {"NativeAgent", "NativeAgentProviders", "NativeAgentLabs"}
SURFACE_TIERS = {"STABLE", "QUALIFICATION_GATED", "EXPERIMENTAL"}
CAPABILITY_STATES = {
    "REACHABLE",
    "PUBLIC_LIBRARY",
    "OPTIONAL_PROVIDER",
    "UNWIRED_LABS",
}
QUALIFICATION_STATUSES = {
    "PASS",
    "FAIL",
    "UNKNOWN",
    "SKIPPED_ENV",
    "NOT_APPLICABLE",
}

# Release-time API guards are intentionally module/symbol based rather than tied
# to implementation filenames. Runtime semantics remain owned by Swift tests.
REQUIRED_PUBLIC_SYMBOLS: dict[str, tuple[str, ...]] = {
    "LanguageModelCore": (
        "ModelClient",
        "ModelRequest",
        "ModelTurn",
        "ModelEvent",
        "ModelDescriptor",
        "AgentMessage",
        "JSONValue",
    ),
    "LanguageModelRuntime": (
        "ModelRuntime",
        "ModelProviderRegistry",
        "ModelRunReservation",
        "ModelRun",
        "ModelRuntimeStatus",
    ),
    "NativeAgent": (
        "Agent",
        "AgentManager",
        "AgentRun",
        "AgentStorage",
        "SkillLibrary",
        "SessionRuntimeStore",
    ),
    "ModelArtifactStore": ("ModelArtifactStore",),
    "ChatGPTAccount": ("ChatGPTAccountSession", "ChatGPTTransport"),
    "ChatGPTText": ("ChatGPTModelClient", "ChatGPTTextSession"),
    "ChatGPTImage": ("ChatGPTImageClient", "ChatGPTImageContent", "ChatGPTImageGenerationRequest", "ChatGPTImageEditRequest"),
    "NativeAgentMCP": ("MCPToolPack",),
    "ChatGPTTextProvider": ("ChatGPTRuntime", "ChatGPTAgentFactory"),
    "ChatGPTImageCapability": ("ChatGPTImagesCapability",),
    "AppleSystemModelProvider": ("AppleSystemModelProvider",),
    "LEAPProvider": ("LeapRuntime",),
    "LiteRTProvider": ("LiteRTProvider",),
    "MLXProvider": ("MLXTextRuntime",),
}


@dataclass(frozen=True)
class Entry:
    rel: str
    data: bytes
    sha256: str
    mode: int


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def ignored(rel: Path) -> bool:
    return (
        any(part in IGNORED_PARTS for part in rel.parts)
        or rel.name in IGNORED_NAMES
    )


def forbidden_generated(rel: Path) -> bool:
    return (
        any(part in FORBIDDEN_PARTS for part in rel.parts)
        or rel.suffix.lower() in FORBIDDEN_SUFFIXES
    )


def allowed_top_level(rel: Path) -> bool:
    if not rel.parts:
        return False
    top = rel.parts[0]
    if len(rel.parts) == 1:
        return top in ALLOWED_TOP_LEVEL_FILES or top in ALLOWED_TOP_LEVEL_DIRS
    return top in ALLOWED_TOP_LEVEL_DIRS


def inventory(root: Path) -> tuple[Entry, ...]:
    entries: list[Entry] = []
    generated: list[str] = []
    outside_allowlist: list[str] = []
    symlinks: list[str] = []

    for path in root.rglob("*"):
        rel_path = path.relative_to(root)
        if ignored(rel_path):
            continue
        if forbidden_generated(rel_path):
            generated.append(rel_path.as_posix())
            continue
        if not allowed_top_level(rel_path):
            outside_allowlist.append(rel_path.as_posix())
            continue
        if path.is_symlink():
            symlinks.append(rel_path.as_posix())
            continue
        if path.is_file():
            data = path.read_bytes()
            mode = 0o755 if (path.stat().st_mode & stat.S_IXUSR) else 0o644
            entries.append(Entry(rel_path.as_posix(), data, digest(data), mode))

    if generated:
        raise ValueError(f"generated/cache paths are present: {sorted(generated)}")
    if outside_allowlist:
        raise ValueError(f"source paths are outside the release allowlist: {sorted(outside_allowlist)}")
    if symlinks:
        raise ValueError(f"symlinks are not allowed in the sealed source archive: {sorted(symlinks)}")

    return tuple(sorted(entries, key=lambda entry: entry.rel))


def text_map(entries: tuple[Entry, ...]) -> dict[str, str]:
    result: dict[str, str] = {}
    for entry in entries:
        try:
            result[entry.rel] = entry.data.decode("utf-8")
        except UnicodeDecodeError:
            continue
    return result


def require_text(texts: dict[str, str], rel: str, failures: list[str]) -> str:
    value = texts.get(rel)
    if value is None:
        failures.append(f"missing UTF-8 source: {rel}")
        return ""
    return value


def load_json(texts: dict[str, str], rel: str, failures: list[str]) -> dict[str, Any] | None:
    raw = require_text(texts, rel, failures)
    if not raw:
        return None
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        failures.append(f"invalid {rel}: {error}")
        return None
    if not isinstance(value, dict):
        failures.append(f"{rel} root must be a JSON object")
        return None
    return value


def package_manifests(texts: dict[str, str]) -> dict[str, str]:
    manifests: dict[str, str] = {}
    if "Package.swift" in texts:
        manifests["NativeAgent"] = texts["Package.swift"]
    for rel, content in texts.items():
        match = re.fullmatch(r"Packages/([^/]+)/Package\.swift", rel)
        if match:
            manifests[match.group(1)] = content
    return manifests


def check_package_manifests(
    texts: dict[str, str], paths: set[str], failures: list[str]
) -> dict[str, str]:
    manifests = package_manifests(texts)
    if not manifests:
        failures.append("no Swift package manifest found at the root or under Packages/")
        return manifests

    local_pattern = re.compile(r'\.package\s*\([^\)]*?path\s*:\s*"([^"]+)"', re.S)
    dependency_pattern = re.compile(r"\.package\s*\((.*?)\)", re.S)
    binary_pattern = re.compile(r"\.binaryTarget\s*\((.*?)\)", re.S)

    for package_dir, content in sorted(manifests.items()):
        manifest_rel = "Package.swift" if package_dir == "NativeAgent" else f"Packages/{package_dir}/Package.swift"
        declared = re.search(r"\bPackage\s*\(\s*name\s*:\s*\"([^\"]+)\"", content, re.S)
        if declared is None:
            failures.append(f"package name is not statically declared: {manifest_rel}")
        elif declared.group(1) != package_dir:
            failures.append(
                f"package directory/name mismatch: {package_dir} != {declared.group(1)}"
            )

        if "// swift-tools-version: 6.2" not in content:
            failures.append(f"Swift tools baseline drifted from 6.2: {manifest_rel}")
        # A binary-only package has no Swift compilation settings. Do not require
        # unused declarations to pretend that it compiles Swift source. All packages
        # with source/test/plugin targets retain the original strict-mode checks.
        binary_only = bool(binary_pattern.search(content)) and not re.search(
            r"\.(?:target|executableTarget|testTarget|systemLibrary|plugin)\s*\(", content
        )
        if not binary_only:
            if "swiftLanguageModes: [.v6]" not in content:
                failures.append(f"Swift 6 language mode is not explicit: {manifest_rel}")
            for feature in ("ExistentialAny", "MemberImportVisibility", "ImmutableWeakCaptures"):
                if feature not in content:
                    failures.append(f"strict Swift feature missing in {manifest_rel}: {feature}")
        if ".iOS(.v16)" in content:
            failures.append(f"iOS 16 compatibility surface remains: {manifest_rel}")

        parent = PurePosixPath(manifest_rel).parent
        for value in local_pattern.findall(content):
            candidate = parent.joinpath(value)
            normalized: list[str] = []
            escaped = False
            for part in candidate.parts:
                if part in ("", "."):
                    continue
                if part == "..":
                    if not normalized:
                        escaped = True
                        break
                    normalized.pop()
                else:
                    normalized.append(part)
            if escaped:
                failures.append(f"package path escapes source root: {manifest_rel} -> {value}")
                continue
            target_manifest = "/".join(normalized + ["Package.swift"])
            if target_manifest not in paths:
                failures.append(
                    f"local package dependency is missing: {manifest_rel} -> {value}"
                )

        for match in dependency_pattern.finditer(content):
            body = match.group(1)
            if "url:" not in body:
                continue
            immutable_revision = re.search(r'\brevision\s*:\s*"[0-9a-fA-F]{40}"', body)
            if "exact:" not in body and immutable_revision is None:
                failures.append(
                    f"remote package dependency must use an exact version or full commit for sealed workspace reproducibility: {manifest_rel}::{body.strip()}"
                )

        for match in binary_pattern.finditer(content):
            body = match.group(1)
            if "url:" in body and "checksum:" not in body:
                failures.append(f"remote binary target lacks checksum: {manifest_rel}")

    return manifests


def declared_library_products(manifest: str) -> set[str]:
    """Return statically declared public library product names from a Package.swift.

    The sealed workspace currently uses direct `.library(name:)` declarations plus
    one simple `let names = ["..."]` / `names.map { .library(name: $0, ...) }`
    expansion. Supporting those two forms keeps release classification checked
    against the manifest without executing package code during source sealing.
    """
    products = set(
        re.findall(r'\.library\s*\(\s*name\s*:\s*"([^"]+)"', manifest)
    )
    for mapping in re.finditer(
        r'\b([A-Za-z_][A-Za-z0-9_]*)\.map\s*\{\s*\.library\s*\(\s*name\s*:\s*\$0',
        manifest,
        re.S,
    ):
        variable = re.escape(mapping.group(1))
        declaration = re.search(
            rf'\blet\s+{variable}\s*=\s*\[(.*?)\]\s*\n',
            manifest,
            re.S,
        )
        if declaration is None:
            continue
        products.update(re.findall(r'"([^"]+)"', declaration.group(1)))
    return products


def check_surfaces(
    texts: dict[str, str], manifests: dict[str, str], failures: list[str]
) -> dict[str, Any] | None:
    payload = load_json(texts, "release/surfaces.json", failures)
    if payload is None:
        return None

    if payload.get("schema") != "native-agent.release-surfaces/1":
        failures.append("release surface schema must be native-agent.release-surfaces/1")

    distribution = payload.get("distribution")
    if not isinstance(distribution, dict):
        failures.append("release distribution contract is missing")
    else:
        if distribution.get("kind") != "SEALED_SOURCE_WORKSPACE":
            failures.append("distribution.kind must be SEALED_SOURCE_WORKSPACE")
        if distribution.get("isInstallContract") is not True:
            failures.append("sealed source workspace must be the install contract")
        if distribution.get("remoteSwiftPMInstallContract") is not False:
            failures.append("remote SwiftPM publication must remain outside this install contract")
        if distribution.get("versionAuthority") != "SURFACE_CONTENT_SHA256":
            failures.append("surface version authority must be SURFACE_CONTENT_SHA256")

    surfaces = payload.get("surfaces")
    if not isinstance(surfaces, list):
        failures.append("release surfaces must be a list")
        return payload
    names = {item.get("name") for item in surfaces if isinstance(item, dict)}
    if names != SURFACE_NAMES:
        failures.append(f"release surfaces must be exactly {sorted(SURFACE_NAMES)}")

    covered_packages: set[str] = set()
    covered_capabilities: set[tuple[str, str]] = set()
    duplicate_capabilities: set[tuple[str, str]] = set()
    qualification_subjects: set[str] = set()
    for surface in surfaces:
        if not isinstance(surface, dict):
            failures.append("release surface entry must be an object")
            continue
        name = surface.get("name")
        tier = surface.get("tier")
        if tier not in SURFACE_TIERS:
            failures.append(f"invalid release tier: {name}::{tier}")
        if surface.get("releaseAuthority") != "INDEPENDENT":
            failures.append(f"surface release authority must be independent: {name}")
        if surface.get("versionAuthority") != "SURFACE_CONTENT_SHA256":
            failures.append(f"surface version authority drifted: {name}")

        packages = surface.get("packages")
        if not isinstance(packages, list) or not all(isinstance(item, str) for item in packages):
            failures.append(f"surface packages must be strings: {name}")
            packages = []
        for package in packages:
            covered_packages.add(package)
            if package not in manifests:
                failures.append(f"release surface references unknown package: {name}::{package}")

        subjects = surface.get("qualificationSubjects")
        if not isinstance(subjects, list) or not subjects or not all(
            isinstance(item, str) and item for item in subjects
        ):
            failures.append(f"qualification subjects are missing: {name}")
        else:
            qualification_subjects.update(subjects)

        capabilities = surface.get("capabilities")
        if not isinstance(capabilities, list) or not capabilities:
            failures.append(f"release capabilities are missing: {name}")
            continue
        for capability in capabilities:
            if not isinstance(capability, dict):
                failures.append(f"capability entry must be an object: {name}")
                continue
            package = capability.get("package")
            product = capability.get("product")
            state = capability.get("state")
            if state not in CAPABILITY_STATES:
                failures.append(f"invalid capability state: {name}::{product}::{state}")
            if package not in manifests:
                failures.append(f"capability references unknown package: {name}::{package}")
                continue
            if not isinstance(product, str) or product not in manifests[package]:
                failures.append(
                    f"release capability is not declared by its package manifest: {package}::{product}"
                )
                continue
            capability_key = (package, product)
            if capability_key in covered_capabilities:
                duplicate_capabilities.add(capability_key)
            covered_capabilities.add(capability_key)

    if duplicate_capabilities:
        failures.append(
            "release capabilities must classify each public product once: "
            + str(sorted(duplicate_capabilities))
        )

    declared_capabilities = {
        (package, product)
        for package, manifest in manifests.items()
        for product in declared_library_products(manifest)
    }
    if covered_capabilities != declared_capabilities:
        missing = sorted(declared_capabilities - covered_capabilities)
        extra = sorted(covered_capabilities - declared_capabilities)
        failures.append(
            f"release capability coverage mismatch: missing={missing}, extra={extra}"
        )

    if covered_packages != set(manifests):
        missing = sorted(set(manifests) - covered_packages)
        extra = sorted(covered_packages - set(manifests))
        failures.append(f"release package coverage mismatch: missing={missing}, extra={extra}")

    payload["_qualificationSubjects"] = sorted(qualification_subjects)
    return payload


def check_qualification(
    texts: dict[str, str], surfaces: dict[str, Any] | None, failures: list[str]
) -> dict[str, Any] | None:
    payload = load_json(texts, "release/qualification.json", failures)
    if payload is None:
        return None
    if payload.get("schema") != "native-agent.qualification/1":
        failures.append("qualification schema must be native-agent.qualification/1")
    if payload.get("currentEvidencePolicy") != "NO_CARRY_FORWARD_WITHOUT_EXPLICIT_SCOPE":
        failures.append("qualification evidence policy must reject implicit carry-forward")

    subjects = payload.get("subjects")
    if not isinstance(subjects, list):
        failures.append("qualification subjects must be a list")
        return payload

    ids: set[str] = set()
    for subject in subjects:
        if not isinstance(subject, dict):
            failures.append("qualification subject must be an object")
            continue
        subject_id = subject.get("id")
        if not isinstance(subject_id, str) or not subject_id:
            failures.append("qualification subject id is missing")
            continue
        if subject_id in ids:
            failures.append(f"duplicate qualification subject: {subject_id}")
        ids.add(subject_id)
        checks = subject.get("checks")
        if not isinstance(checks, list) or not checks:
            failures.append(f"qualification checks missing: {subject_id}")
            continue
        check_ids: set[str] = set()
        for check in checks:
            if not isinstance(check, dict):
                failures.append(f"qualification check must be an object: {subject_id}")
                continue
            check_id = check.get("id")
            if not isinstance(check_id, str) or not check_id:
                failures.append(f"qualification check id missing: {subject_id}")
                continue
            if check_id in check_ids:
                failures.append(f"duplicate qualification check: {subject_id}::{check_id}")
            check_ids.add(check_id)
            status = check.get("status")
            if status not in QUALIFICATION_STATUSES:
                failures.append(
                    f"invalid qualification status: {subject_id}::{check_id}::{status}"
                )
            historical = check.get("historicalEvidence")
            if historical is not None:
                if not isinstance(historical, dict):
                    failures.append(
                        f"historical evidence must be an object: {subject_id}::{check_id}"
                    )
                elif historical.get("status") != "PASS":
                    failures.append(
                        f"historical evidence may record only explicit PASS observations: {subject_id}::{check_id}"
                    )

    if surfaces is not None:
        required = set(surfaces.get("_qualificationSubjects", []))
        if ids != required:
            failures.append(
                f"qualification subject coverage mismatch: missing={sorted(required - ids)}, extra={sorted(ids - required)}"
            )
    return payload


def public_declarations(source: str) -> set[str]:
    pattern = re.compile(
        r"\bpublic\s+(?:final\s+)?(?:actor|struct|class|enum|protocol|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)"
    )
    return set(pattern.findall(source))


def check_public_api(texts: dict[str, str], failures: list[str]) -> None:
    for module, required in REQUIRED_PUBLIC_SYMBOLS.items():
        prefix = "Sources/" if module == "NativeAgent" else f"Packages/{module}/Sources/"
        module_text = "\n".join(
            content
            for rel, content in texts.items()
            if rel.startswith(prefix) and rel.endswith(".swift")
        )
        if not module_text:
            failures.append(f"public API source missing for package: {module}")
            continue
        declared = public_declarations(module_text)
        for symbol in required:
            if symbol not in declared:
                failures.append(f"required public symbol missing: {module}::{symbol}")


def check_device_qualification_host(
    texts: dict[str, str], paths: set[str], failures: list[str]
) -> None:
    prefix = "Packages/MLXProvider/DeviceQualification/"
    required = (
        prefix + "project.yml",
        prefix + "NativeAgentMLXDeviceQualification.xcodeproj/project.pbxproj",
        prefix
        + "NativeAgentMLXDeviceQualification.xcodeproj/xcshareddata/xcschemes/"
        + "NativeAgentMLXDeviceQualification.xcscheme",
        prefix + "App/App.swift",
        prefix + "App/QualificationRunner.swift",
        prefix + "Tests/NativeAgentMLXDeviceQualificationTests.swift",
    )
    for rel in required:
        if rel not in paths:
            failures.append(f"MLX device qualification host source missing: {rel}")

    project = texts.get(prefix + "project.yml", "")
    for contract in (
        "type: application",
        "type: bundle.unit-test",
        'TEST_HOST: "$(BUILT_PRODUCTS_DIR)/NativeAgentMLXDeviceQualification.app/',
        "product: NativeAgent",
        "product: MLXProvider",
    ):
        if contract not in project:
            failures.append(f"MLX device qualification host wiring missing: {contract}")

    runner = texts.get(prefix + "App/QualificationRunner.swift", "")
    for contract in (
        "mlx-community/Qwen3.5-0.8B-MLX-4bit",
        "5d894f8cc4ef3e6c88537bf3746ed262f549da6a",
        "runtime.prepare(model)",
        "runtime.loadRuntime",
        "Agent(",
        "agent.session(id: sessionID)",
        "requiredToken",
        "cancelActiveRun()",
        "cancellationDrainObserved",
        "modelRuntime.shutdown()",
    ):
        if contract not in runner:
            failures.append(f"MLX device qualification runtime contract missing: {contract}")

    test = texts.get(prefix + "Tests/NativeAgentMLXDeviceQualificationTests.swift", "")
    if "NativeAgentMLXDeviceQualificationRunner.run()" not in test:
        failures.append("MLX device qualification test is not wired to the real runner")


def contract_audit(root: Path, entries: tuple[Entry, ...]) -> tuple[list[str], dict[str, Any]]:
    failures: list[str] = []
    paths = {entry.rel for entry in entries}
    texts = text_map(entries)

    for output in FORBIDDEN_SOURCE_OUTPUTS:
        if output in paths or any(path.startswith(output + "/") for path in paths):
            failures.append(f"generated release evidence must stay outside source: {output}")

    scripts = sorted(
        path
        for path in paths
        if path.startswith("scripts/") and path.endswith((".py", ".sh"))
    )
    if scripts != [
        "scripts/check_verify_local.py",
        "scripts/release.py",
        "scripts/sign_leap_embedded.sh",
        "scripts/verify_local.py",
    ]:
        failures.append(f"unexpected release/local-verification tooling entries: {scripts}")

    for required in (
        "LICENSE",
        "README.md",
        "docs/ARCHITECTURE.md",
        "docs/AGENT_MANAGEMENT.md",
        "docs/DISTRIBUTION.md",
        "docs/PROVIDERS.md",
        "docs/QUALIFICATION.md",
        "docs/PLAN.md",
        "docs/VERIFICATION.md",
        "release/surfaces.json",
        "release/qualification.json",
    ):
        if required not in paths:
            failures.append(f"missing release source: {required}")

    manifests = check_package_manifests(texts, paths, failures)
    surfaces = check_surfaces(texts, manifests, failures)
    qualification = check_qualification(texts, surfaces, failures)
    check_public_api(texts, failures)
    check_device_qualification_host(texts, paths, failures)

    return failures, {
        "manifests": manifests,
        "surfaces": surfaces,
        "qualification": qualification,
    }


def manifest_text(entries: tuple[Entry, ...]) -> str:
    return "".join(f"{entry.sha256}  {entry.rel}\n" for entry in entries)


def tree_text(entries: tuple[Entry, ...]) -> str:
    return "".join(f"{entry.rel}\n" for entry in entries)


def surface_versions(
    entries: tuple[Entry, ...], surfaces_payload: dict[str, Any] | None
) -> dict[str, dict[str, str]]:
    if surfaces_payload is None:
        return {}
    versions: dict[str, dict[str, str]] = {}
    for surface in surfaces_payload.get("surfaces", []):
        if not isinstance(surface, dict):
            continue
        name = surface.get("name")
        packages = surface.get("packages", [])
        if not isinstance(name, str) or not isinstance(packages, list):
            continue
        prefixes = tuple(f"Packages/{package}/" for package in packages
                         if isinstance(package, str) and package != "NativeAgent")
        if "NativeAgent" in packages:
            prefixes += ("Sources/", "Tests/", "Qualification/ResponsePolicies/")
        selected = tuple(entry for entry in entries
                         if entry.rel.startswith(prefixes)
                         or ("NativeAgent" in packages and entry.rel == "Package.swift"))
        authority = {
            key: value
            for key, value in surface.items()
            if key in {
                "name",
                "tier",
                "releaseAuthority",
                "versionAuthority",
                "packages",
                "capabilities",
                "qualificationSubjects",
            }
        }
        payload = (
            json.dumps(authority, sort_keys=True, separators=(",", ":"))
            + "\n"
            + manifest_text(selected)
        ).encode("utf-8")
        versions[name] = {
            "algorithm": "sha256",
            "digest": digest(payload),
        }
    return versions


def qualification_summary(payload: dict[str, Any] | None) -> dict[str, dict[str, int]]:
    if payload is None:
        return {}
    result: dict[str, dict[str, int]] = {}
    for subject in payload.get("subjects", []):
        if not isinstance(subject, dict) or not isinstance(subject.get("id"), str):
            continue
        counts: dict[str, int] = {}
        for check in subject.get("checks", []):
            if not isinstance(check, dict):
                continue
            status = check.get("status")
            if isinstance(status, str):
                counts[status] = counts.get(status, 0) + 1
        result[subject["id"]] = counts
    return result


def write_zip(entries: tuple[Entry, ...], root_name: str, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        output.unlink()
    prefix = root_name.rstrip("/") + "/"
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for entry in entries:
            info = zipfile.ZipInfo(prefix + entry.rel, FIXED_ZIP_TIME)
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | entry.mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            info.flag_bits |= 0x800
            archive.writestr(
                info,
                entry.data,
                compress_type=zipfile.ZIP_DEFLATED,
                compresslevel=9,
            )


def verify_zip_bytes(entries: tuple[Entry, ...], root_name: str, output: Path) -> None:
    prefix = root_name.rstrip("/") + "/"
    expected = [prefix + entry.rel for entry in entries]
    with zipfile.ZipFile(output) as archive:
        bad = archive.testzip()
        if bad is not None:
            raise ValueError(f"ZIP CRC check failed: {bad}")
        if archive.namelist() != expected:
            raise ValueError("ZIP entry order/tree differs from the captured source inventory")
        for entry, name in zip(entries, expected):
            if archive.read(name) != entry.data:
                raise ValueError(f"ZIP byte mismatch: {entry.rel}")
            mode = (archive.getinfo(name).external_attr >> 16) & 0o777
            if mode != entry.mode:
                raise ValueError(
                    f"ZIP mode mismatch: {entry.rel}: {oct(mode)} != {oct(entry.mode)}"
                )


def entry_identity(entries: tuple[Entry, ...]) -> tuple[tuple[str, str, int], ...]:
    return tuple((entry.rel, entry.sha256, entry.mode) for entry in entries)


def safe_extract(archive: zipfile.ZipFile, destination: Path) -> str:
    infos = archive.infolist()
    if not infos:
        raise ValueError("archive is empty")
    roots: set[str] = set()
    for info in infos:
        path = PurePosixPath(info.filename)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError(f"unsafe archive path: {info.filename}")
        if not path.parts:
            raise ValueError("archive contains an empty path")
        roots.add(path.parts[0])
        if info.is_dir():
            continue
        target = destination.joinpath(*path.parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(archive.read(info))
        mode = (info.external_attr >> 16) & 0o777
        if mode not in (0o644, 0o755):
            raise ValueError(f"unsupported archive mode: {info.filename}: {oct(mode)}")
        target.chmod(mode)
    if len(roots) != 1:
        raise ValueError(f"archive must contain exactly one root directory: {sorted(roots)}")
    return next(iter(roots))


def verify_extracted_archive(
    source_entries: tuple[Entry, ...] | None,
    archive_path: Path,
    expected_root_name: str | None = None,
) -> tuple[tuple[Entry, ...], dict[str, Any]]:
    with tempfile.TemporaryDirectory(prefix="native-agent-release-") as temporary:
        destination = Path(temporary)
        with zipfile.ZipFile(archive_path) as archive:
            bad = archive.testzip()
            if bad is not None:
                raise ValueError(f"ZIP CRC check failed: {bad}")
            root_name = safe_extract(archive, destination)
        if expected_root_name is not None and root_name != expected_root_name:
            raise ValueError(f"archive root mismatch: {root_name} != {expected_root_name}")

        extracted_root = destination / root_name
        extracted_entries = inventory(extracted_root)
        failures, audit = contract_audit(extracted_root, extracted_entries)
        if failures:
            raise ValueError("extracted source audit failed: " + "; ".join(failures))
        if source_entries is not None and entry_identity(extracted_entries) != entry_identity(source_entries):
            raise ValueError("extracted path/content-SHA/mode differs from captured source inventory")
        return extracted_entries, audit


def write_evidence(
    entries: tuple[Entry, ...],
    output: Path,
    zip_digest: str,
    audit: dict[str, Any],
) -> None:
    stem = output.with_suffix("")
    manifest = stem.with_name(stem.name + ".manifest.sha256")
    tree = stem.with_name(stem.name + ".source-tree.txt")
    report = stem.with_name(stem.name + ".report.json")
    sha = output.with_suffix(output.suffix + ".sha256")

    manifest.write_text(manifest_text(entries), encoding="utf-8")
    tree.write_text(tree_text(entries), encoding="utf-8")
    sha.write_text(f"{zip_digest}  {output.name}\n", encoding="utf-8")
    report.write_text(
        json.dumps(
            {
                "schema": "native-agent.release-report/1",
                "status": "SEALED_SOURCE_WORKSPACE",
                "sourceFileCount": len(entries),
                "archive": output.name,
                "sha256": zip_digest,
                "archiveSeal": {
                    "zipCRC": "PASS",
                    "zipByteAndModeMatch": "PASS",
                    "extractedStaticAudit": "PASS",
                    "extractedPathContentSHA256ModeMatch": "PASS",
                },
                "surfaceVersions": surface_versions(entries, audit.get("surfaces")),
                "qualificationSummary": qualification_summary(audit.get("qualification")),
                "runtimeVerification": "NOT_RUN_BY_RELEASE_SCRIPT",
                "buildVerification": "NOT_RUN_BY_RELEASE_SCRIPT",
                "testVerification": "NOT_RUN_BY_RELEASE_SCRIPT",
                "sourceEvidenceLocation": "external-to-source-archive",
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


def execute_verify(root: Path) -> int:
    entries = inventory(root)
    failures, _ = contract_audit(root, entries)
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    print(
        f"STATIC SOURCE AUDIT PASS: {len(entries)} files; Finder/VCS metadata ignored; build/test/runtime not executed"
    )
    return 0


def execute_package(root: Path, output: Path) -> int:
    entries = inventory(root)
    failures, audit = contract_audit(root, entries)
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1

    try:
        output.resolve().relative_to(root.resolve())
    except ValueError:
        pass
    else:
        print("FAIL: release output must stay outside the source root", file=sys.stderr)
        return 1

    write_zip(entries, root.name, output)
    verify_zip_bytes(entries, root.name, output)
    verify_extracted_archive(entries, output, root.name)
    zip_digest = digest(output.read_bytes())
    write_evidence(entries, output, zip_digest, audit)
    print(f"STATIC SOURCE AUDIT PASS: {len(entries)} files")
    print("ARCHIVE SEAL PASS: CRC + byte/mode + extracted audit + path/SHA-256/mode exact match")
    print(f"PACKAGED: {output}")
    print(f"SHA256: {zip_digest}")
    return 0


def execute_verify_archive(archive: Path) -> int:
    extracted_entries, _ = verify_extracted_archive(None, archive)
    print(
        f"ARCHIVE VERIFY PASS: {len(extracted_entries)} files; CRC + extracted static audit; build/test/runtime not executed"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Single release authority: allowlisted inventory -> manifest/API/surface audit -> "
            "deterministic archive -> extracted seal verification."
        )
    )
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("verify", help="Run the static source-contract audit only.")
    package = sub.add_parser("package", help="Audit and create a sealed deterministic source ZIP.")
    package.add_argument("--output", type=Path, required=True)
    verify_archive = sub.add_parser(
        "verify-archive", help="Extract and verify a previously sealed source ZIP."
    )
    verify_archive.add_argument("--archive", type=Path, required=True)
    args = parser.parse_args()

    try:
        if args.command == "verify":
            return execute_verify(args.root.resolve())
        if args.command == "package":
            return execute_package(args.root.resolve(), args.output.resolve())
        return execute_verify_archive(args.archive.resolve())
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
