#!/usr/bin/env python3
"""NativeAI source/graph/syntax guards. Never a native SDK or inference qualification."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import argparse, hashlib, json, os, platform, re, subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(os.environ.get("NATIVEAI_VERIFICATION_OUTPUT", ROOT / "docs/verification/current")).resolve()
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
sdk_manifest = ROOT / "Providers/LEAP/Packages/NativeAILeapSDK/Package.swift"
check("LeapSDK declarations belong to leaf owner and root distribution",
      set(binary) == {ROOT / "Package.swift", sdk_manifest}, "same binary in two independent consumption graphs")
def binary_binding(manifest):
    declaration = re.search(r'\.binaryTarget\(\s*name:\s*"LeapSDK"[^)]*\)', manifest.read_text(), re.S)
    if declaration is None:
        return None
    return tuple(re.search(rf'{field}:\s*"([^"]+)"', declaration[0])[1] for field in ('url', 'checksum'))
check("root LeapSDK preserves leaf URL and checksum",
      binary_binding(ROOT / "Package.swift") == binary_binding(sdk_manifest), "distribution artifact identity")
check("LEAP consumes its native owner", '.product(name: "LeapSDK", package: "NativeAILeapSDK")' in read("Providers/LEAP/Package.swift"), "native package dependency")
check("Retired generate-only stream default is absent",
      "ModelFallbackStreamState" not in (ROOT / "Model/LanguageModelCore/Sources/LanguageModelCore/Contracts/ModelClient.swift").read_text(), "retirement")
check("Retired stream-only transport default is absent",
      "public extension ChatGPTTransport" not in (ROOT / "Providers/ChatGPT/Account/Sources/ChatGPTAccount/ChatGPTTransport.swift").read_text(), "retirement")
check("Provider registry uses explicit runtime acquisition only",
      "func makeRuntime" not in (ROOT / "Model/LanguageModelRuntime/Sources/LanguageModelRuntime/ModelProviderRegistry.swift").read_text(), "retirement")
check("LEAP previous cache/session adoption is absent",
      ".downloads.v1" not in (ROOT / "Providers/LEAP/Sources/LEAPProvider/Downloader.swift").read_text()
      and "func bind(" not in (ROOT / "Providers/LEAP/Sources/LEAPProvider/Downloader.swift").read_text(), "retirement")
check("MapKit placemark API is absent",
      ".placemark" not in (ROOT / "Agent/NativeAgentPackage/Sources/NativeAgentTools/Maps/MapSearchToolPack.swift").read_text(), "retirement")
check("Retired migration entrypoints are absent",
      not any((HOLD / path).is_file() for path in ("AppleLocalAI/Package.swift", "NativeAgentRelease/scripts/release.py")),
      "explicit source/API retirement; ignored caches are outside scope")
for url, version in (("https://github.com/ml-explore/mlx-swift", "0.32.3"),
                     ("https://github.com/ml-explore/mlx-swift-lm", "3.32.3")):
    pattern = re.escape(url) + r'"\s*,\s*exact:\s*"' + re.escape(version) + '"'
    check("Current exact MLX pin: " + version,
          all(re.search(pattern, read(path)) for path in ("Package.swift", "Providers/MLX/Package.swift")),
          "declared versions; actual resolver/runtime qualification recorded separately")
engine_owner = [p for p in manifests if re.search(r'\.binaryTarget\(\s*name:\s*"inference_engine"', p.read_text())]
check("LEAP sibling engine belongs to native owner and root", set(engine_owner) == {ROOT / "Package.swift", sdk_manifest}, "0.11 framework layout")
check("LEAP product includes the sibling engine", 'targets: ["LeapSDK", "inference_engine"]' in read("Providers/LEAP/Packages/NativeAILeapSDK/Package.swift"), "SwiftPM embed/sign dependency")

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
    "manifestCount": len(manifests),
    "staticAssertions": len(checks), "syntaxFiles": len(syntax), "syntaxStatus": "NOT_RUN" if args.skip_syntax else "EXECUTED",
    "checks": checks, "syntax": syntax,
    "limits": ["No remote dependency resolution, native SDK typecheck, linker or device proof.",
               "Source guards and syntax parsing are not model inference evidence."]}
OUT.mkdir(parents=True, exist_ok=True)
(OUT / "static-checks.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({k: v for k, v in report.items() if k not in {"checks", "syntax"}}, ensure_ascii=False, indent=2))
for item in checks + syntax:
    if item["status"] != "PASS": print(json.dumps(item, ensure_ascii=False))
raise SystemExit(0 if report["status"] == "PASS" else 1)
