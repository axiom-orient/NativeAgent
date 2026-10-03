#!/usr/bin/env python3
"""NativeAI source/graph/syntax guards. Never a native SDK or inference qualification."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import argparse, hashlib, json, platform, re, subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs/verification/current"
HOLD = ROOT / "MigrationHold"
IGNORED = {".git", ".build", ".swiftpm", "__pycache__", "design-input", "imported-baseline"}
checks = []

def check(name, condition, scope):
    checks.append({"name": name, "status": "PASS" if condition else "FAIL", "scope": scope})

def read(relative):
    return (ROOT / relative).read_text()

def sources(package):
    return sorted((package / "Sources").rglob("*.swift"))

def imports(text):
    pattern = r"^\s*(?:@[_A-Za-z]\w*(?:\([^)]*\))?\s+)*(?:(?:public|internal|package|private|fileprivate)\s+)?import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_]\w*)"
    return set(re.findall(pattern, text, re.M))

def source_text(package):
    return "\n".join(p.read_text() for p in sources(package))

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--skip-syntax", action="store_true", help="Graph/source guards only; syntax is explicitly NOT_RUN")
args = parser.parse_args()
manifests = sorted(p for p in ROOT.rglob("Package.swift") if not IGNORED.intersection(p.parts))
graph = {}
for manifest in manifests:
    edges = []
    local_aliases = set()
    external_aliases = set()
    text = manifest.read_text()
    for declaration in re.findall(r"\.package\s*\(([^)]*)\)", text, re.S):
        match = re.search(r'path\s*:\s*"([^"]+)"', declaration)
        alias = re.search(r'name\s*:\s*"([^"]+)"', declaration)
        url = re.search(r'url\s*:\s*"([^"]+)"', declaration)
        if match:
            relative = match[1]
            target = (manifest.parent / relative).resolve()
            valid = not Path(relative).is_absolute() and target.is_relative_to(ROOT) and (target / "Package.swift").is_file()
            check("local dependency: " + str(manifest.relative_to(ROOT)) + " -> " + relative, valid, "declared local SwiftPM edge")
            edges.append(target)
            local_aliases.add((alias[1] if alias else target.name).lower())
        elif url:
            external_aliases.add((alias[1] if alias else url[1].rstrip('/').split('/')[-1].removesuffix('.git')).lower())
    graph[manifest.parent] = edges
    # Renaming a directory changes SwiftPM's default identity, even when product name is stable.
    for alias in re.findall(r'\.product\([^)]*?package:\s*"([^"]+)"', text, re.S):
        check("product package identity: " + str(manifest.relative_to(ROOT)) + " :: " + alias,
              alias.lower() in local_aliases | external_aliases, "declared dependency alias, not remote resolution")
    if not manifest.is_relative_to(HOLD):
        check("active package cannot depend on migration hold: " + str(manifest.relative_to(ROOT)),
              not any(edge.is_relative_to(HOLD) for edge in edges), "P8 quarantine boundary")

visited, visiting = set(), set()
def acyclic(node):
    if node in visiting: return False
    if node in visited: return True
    visiting.add(node)
    result = all(acyclic(edge) for edge in graph.get(node, []))
    visiting.remove(node); visited.add(node)
    return result
check("local package graph is acyclic", all(acyclic(node) for node in graph), "all local manifests")

for relative in ("Agent/NativeAgentPackage", "Model/LanguageModelCore", "Model/LanguageModelRuntime",
                 "Model/NativeLanguageModels", "Model/FoundationModelsBridge", "Model/ModelArtifactStore",
                 "Model/ModelHub", "Providers/AppleSystemModel", "Providers/MLX", "Providers/LiteRT",
                 "Providers/LEAP", "Providers/ChatGPT/Account", "Providers/ChatGPT/Text",
                 "Providers/ChatGPT/TextProvider", "Providers/ChatGPT/Image", "Knowledge/ASK",
                 "Knowledge/ASK/Packages/ASKAgentTools"):
    check("required package exists: " + relative, (ROOT / relative / "Package.swift").is_file(), relative)

check("Agent kernel selects only Core and Runtime", set(graph[ROOT / "Agent/NativeAgentPackage"]) == {
    ROOT / "Model/LanguageModelCore", ROOT / "Model/LanguageModelRuntime"}, "Agent root manifest")
check("Runtime selects only Core", set(graph[ROOT / "Model/LanguageModelRuntime"]) == {
    ROOT / "Model/LanguageModelCore"}, "Runtime manifest")
check("Core has no package dependencies", graph[ROOT / "Model/LanguageModelCore"] == [], "Core manifest")
check("ASK root does not select its optional Agent adapter", ROOT / "Knowledge/ASK/Packages/ASKAgentTools" not in graph[ROOT / "Knowledge/ASK"], "ASK manifest")

for manifest in manifests:
    package = manifest.parent
    text = source_text(package)
    actual_imports = imports(text)
    relative = str(package.relative_to(ROOT))
    if package.is_relative_to(ROOT / "Providers"):
        check("provider has no Agent/ASK imports: " + relative,
              not any(name.startswith("NativeAgent") or name in {"ASK", "NativeLanguageModels"} for name in actual_imports), relative + "/Sources")
    if package == ROOT / "Agent/NativeAgentPackage":
        check("Agent has no concrete provider imports", not actual_imports.intersection({
            "FoundationModels", "MLX", "MLXProvider", "LiteRTProvider", "LEAPProvider", "LeapSDK",
            "ChatGPTAccount", "ChatGPTText", "ChatGPTTextProvider", "ChatGPTImage", "ASK"}), relative + "/Sources")
    if package in {ROOT / "Model/LanguageModelCore", ROOT / "Model/LanguageModelRuntime"}:
        check("common model has no Agent/vendor/knowledge imports: " + relative,
              not any(name.startswith("NativeAgent") or name in {
                  "FoundationModels", "MLX", "MLXLLM", "LeapSDK", "CLiteRTLM", "ASK", "ChatGPTAccount"
              } for name in actual_imports), relative + "/Sources")
    if package == ROOT / "Knowledge/ASK":
        check("ASK root has no Agent imports", not any(name.startswith("NativeAgent") for name in actual_imports), relative + "/Sources")

facade = source_text(ROOT / "Model/NativeLanguageModels")
check("façade does not create a second task/executor/store/IO authority",
      not any(token in facade for token in ("Task {", "Task.detached", "actor ", "URLSession", "FileManager", "ModelExecutorStore()", "ModelRuntime(")), "NativeLanguageModels/Sources")
check("façade delegates conversation to Runtime", "private let session: ModelSession" in facade and "session.respond(" in facade, "NativeLanguageModels/Sources")
check("client/executor projection is an effect boundary outside Core",
      (ROOT / "Model/LanguageModelRuntime/Sources/LanguageModelRuntime/ClientLanguageModel.swift").is_file()
      and not (ROOT / "Model/LanguageModelCore/Sources/LanguageModelCore/Contracts/ClientLanguageModel.swift").exists(), "ModelClient migration")
bridge = source_text(ROOT / "Model/FoundationModelsBridge")
check("Apple 27 symbols have SDK-module and OS gates", "#if canImport(FoundationModels, _version: 2)" in bridge and "@available(iOS 27.0" in bridge, "FoundationModelsBridge/Sources")
check("Apple bridge advertises implemented text scope only", "capabilities: .textOnly" in bridge and "Task {" not in bridge, "Native SDK typecheck/inference remain a separate gate")
ask_adapter = source_text(ROOT / "Knowledge/ASK/Packages/ASKAgentTools")
check("ASK adapter calls canonical plan/dryRun/apply/query", all(value in ask_adapter for value in ("client.plan(", "client.dryRun(", "client.apply(", "client.query(")), "optional ASK adapter")
check("ASK mutation always requires approval and exact bound plan",
      bool(re.search(r"approvalPolicy:\s*\.requireApproval,\s*effect:\s*\.mutation", ask_adapter)) and "call.arguments == expected" in ask_adapter,
      "Kernel performs approval; direct executor calls remain trusted-host operations")
check("ASK adapter creates no store, replica or worker task", not any(value in ask_adapter for value in ("FileManager", "SQLite", "Task {", "Task.detached")), "ASK adapter is a contract projection")
factory = read("Agent/NativeAgentPackage/Packages/ChatGPTAgent/Sources/ChatGPTAgent/ChatGPTAgentFactory.swift")
check("ChatGPT Agent factory preserves auth-before-mutation",
      factory.index("admitRuntimeCreation(") < factory.index("manager.createAgent("), "optional ChatGPTAgent adapter")
check("ChatGPT text factory does not install image effects",
      not any(value in factory for value in ("ChatGPTImageClient(", "ChatGPTImagesCapability(", "installImageSkills")), "optional ChatGPTAgent adapter")
check("ChatGPT text factory preserves supplied skill service", "skillIntentService: skillIntentService" in factory, "host composition")

binary = [p for p in manifests if re.search(r'\.binaryTarget\(\s*name:\s*"LeapSDK"', p.read_text())]
check("exactly one LeapSDK binary declaration", binary == [ROOT / "Providers/LEAP/Packages/NativeAILeapSDK/Package.swift"], "binary identity only, not SDK availability")
for relative in ("Providers/LEAP/Package.swift", "MigrationHold/AppleLocalAI/Packages/AppleLocalAILEAP/Package.swift"):
    check("shared LeapSDK dependency: " + relative, '.product(name: "LeapSDK", package: "NativeAILeapSDK")' in read(relative), "one binary owner")
for revision in ("901941965d82e4a216d4d117231d847d194c563d", "c6446cf7bfb7cea76408013b614d4b2c530eaa03"):
    check("existing MLX revision preserved: " + revision,
          revision in read("Providers/MLX/Package.swift") and revision in read("MigrationHold/AppleLocalAI/Packages/AppleLocalAILocalModels/Package.swift"), "declaration only, not dependency resolution")

# Preserve earlier failure-specific guards for the held native implementations.
for file, load_result in [('AppleLocalAILEAP.swift', 'return LEAPLanguageModel('), ('LEAPAudio.swift', 'return AppleLocalAILEAPAudioModel(')]:
    path = f'MigrationHold/AppleLocalAI/Packages/AppleLocalAILEAP/Sources/AppleLocalAILEAP/{file}'
    text = read(path)
    check(f'{file}: activity enum replaces boolean', 'private var activity: LEAPRuntimeActivity = .idle' in text and 'generationActive' not in text, path)
    # Exact implementation snippets deliberately make the guard fail on structural changes;
    # these only prove source order, not scheduler/native SDK behavior.
    native_load = r'Leap\.shared\.load' if file == 'AppleLocalAILEAP.swift' else r'LeapInferenceEngine\.shared\.loadModel'
    check(f'{file}: load reserves before native await', bool(re.search(r'activity = \.loading\s+defer \{ activity = \.idle \}\s+do \{\s+runner = try await ' + native_load, text)), path)
    check(f'{file}: unload reserves before native await', bool(re.search(r'activity = \.unloading\s+defer \{ activity = \.idle \}\s+do \{\s+try await runner\.unload\(', text)), path)
    check(f'{file}: cancelled load cannot publish successful handle', bool(re.search(r'try Task\.checkCancellation\(\)\s+' + re.escape(load_result), text)), path)
artifact_path = 'MigrationHold/AppleLocalAI/Packages/AppleLocalAILEAP/Sources/AppleLocalAILEAP/LEAPArtifactStore.swift'
artifact = read(artifact_path)
check('LEAP verified cache is checked before acquisition disk reserve', artifact.index('try validate(file: destination') < artifact.index('try checkDiskCapacity('), artifact_path)
check('LEAP cached admission has no wrapping size sum', 'files.reduce(UInt64(0))' not in artifact and 'requiredArtifactBytes: file.byteCount' in artifact, artifact_path)
check('LEAP prepare observes cancellation before empty result', artifact.index('try Task.checkCancellation()') < artifact.index('guard !files.isEmpty'), artifact_path)
text_path = 'MigrationHold/AppleLocalAI/Packages/AppleLocalAILEAP/Sources/AppleLocalAILEAP/AppleLocalAILEAP.swift'
text = read(text_path)
generation = text[text.index('  func generate('):]
check('LEAP Text re-reads resident runner after awaiting warmup', generation.index('let runner else') > generation.index('try await warmupTask.value'), text_path)


command = ["sh", str(ROOT / "MigrationHold/AppleLocalAI/scripts/check-architecture.sh")]
result = subprocess.run(command, capture_output=True, text=True, timeout=30)
checks.append({"name": "migration-hold architecture guard", "status": "PASS" if result.returncode == 0 else "FAIL", "exitCode": result.returncode, "output": result.stdout + result.stderr, "scope": "held code ONLY; not production qualification"})

for config in sorted(ROOT.rglob("project.yml")):
    section = re.search(r"^packages:\n(.*?)(?=^[A-Za-z]|\Z)", config.read_text(), re.M | re.S)
    for relative in re.findall(r"^    path:\s*(\S+)", section[1] if section else "", re.M):
        target = (config.parent / relative.strip('"')).resolve()
        check("XcodeGen local package: " + str(config.relative_to(ROOT)), target.is_relative_to(ROOT) and (target / "Package.swift").is_file(), relative)
for config in sorted(ROOT.rglob("project.pbxproj")):
    for relative in re.findall(r"relativePath\s*=\s*([^;]+);", config.read_text()):
        target = (config.parent.parent / relative.strip().strip('"')).resolve()
        check("Xcode local package: " + str(config.relative_to(ROOT)), target.is_relative_to(ROOT) and (target / "Package.swift").is_file(), relative)

syntax = []
if not args.skip_syntax:
    files = sorted(p for p in ROOT.rglob("*.swift") if p.name != "Package.swift" and not IGNORED.intersection(p.parts))
    def parse(path):
        completed = subprocess.run(["swiftc", "-frontend", "-parse", str(path)], capture_output=True, text=True, timeout=30)
        return {"source": str(path.relative_to(ROOT)), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "status": "PASS" if completed.returncode == 0 else "FAIL", "exitCode": completed.returncode,
                "diagnostic": completed.stderr, "scope": "syntax ONLY, not imports/typecheck/link/inference"}
    with ThreadPoolExecutor(max_workers=4) as pool:
        syntax = list(pool.map(parse, files))

report = {
    "status": "PASS" if all(c["status"] == "PASS" for c in checks + syntax) else "FAIL",
    "platform": platform.platform(), "swift": subprocess.check_output(["swift", "--version"], text=True).strip(),
    "manifestCount": len(manifests), "heldManifestCount": sum(p.is_relative_to(HOLD) for p in manifests),
    "staticAssertions": len(checks), "syntaxFiles": len(syntax), "syntaxStatus": "NOT_RUN" if args.skip_syntax else "EXECUTED",
    "checks": checks, "syntax": syntax,
    "limits": ["No remote dependency resolution, native SDK typecheck, linker or device proof.",
               "MigrationHold is excluded from the active dependency graph, not deleted. P8 is NOT_COMPLETE.",
               "Source guards and syntax parsing are not model inference evidence."]}
OUT.mkdir(parents=True, exist_ok=True)
(OUT / "static-checks.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({k: v for k, v in report.items() if k not in {"checks", "syntax"}}, ensure_ascii=False, indent=2))
for item in checks + syntax:
    if item["status"] != "PASS": print(json.dumps(item, ensure_ascii=False))
raise SystemExit(0 if report["status"] == "PASS" else 1)
