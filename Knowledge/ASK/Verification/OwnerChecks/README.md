# Exact-source owner checks

This optional verification harness selects byte-identical production files and existing/new tests. It does not replace unavailable implementations with stubs. Selection and SHA-256 for every copied file are recorded in `source-hashes.json`.

```sh
python3 Verification/OwnerChecks/prepare.py /absolute/new/owner-checks
swift test --package-path /absolute/new/owner-checks -j 4 -Xswiftc -warnings-as-errors
```

Included: full local KnowledgeCore/KnowledgeRuntime dependency packages; PageIndex Core/Workspace/RAG (excluding format extraction in SourceArtifacts); full EvidenceIndex, HTMLDocument and SourceCapture; WorkWiki Runtime; ASKApplication configuration/coordinator; root ASK planning/contracts/diagnostic/containment/footprint/repair-token code. Tests exercise real stores, source files, capture imports and journal-backed report decisions. Existing HTTP policy tests use a controlled transport; they do not qualify live network access.

Excluded: root executor/client compilation as a whole, Markdown/PDF extraction, document renderers, Apple UI/Foundation Models, full app/runtime graph and SwiftMCP transport. A passing owner run **is not a passing root build or release qualification**. Full supported-environment gates remain in `Scripts/`.

## Actual process termination

On Linux or macOS with clang, the following interposes successful filesystem calls in the real compiled IndexDriver. Linux uses ELF `LD_PRELOAD`; macOS uses dyld `__interpose` with `DYLD_INSERT_LIBRARIES`. The driver invokes public SourceIndexStore APIs; production code has no crash hooks. Use the local verification supervisor to retain process custody and teardown evidence.

```sh
python3 Verification/OwnerChecks/check_process_death.py \
  /absolute/new/owner-checks/.build/debug/IndexDriver \
  /absolute/new/process-death-evidence
```

It requires exit code 90 at eight selected publication/deletion/recovery boundaries, verifies read refusal while a transaction is pending, restores and hashes the prior state, checks idempotent recovery, and observes the committed state after the commit point. It also proves a subsequent write performs recovery without retaining the aborted revision.

This is process-death evidence on the host filesystem only. It does not simulate power failure, broken storage hardware, hostile concurrent symlink replacement or another device's filesystem. macOS interposition requires an executable that permits dyld injection; a missing injected exit is a failed qualification, never a skipped success.
