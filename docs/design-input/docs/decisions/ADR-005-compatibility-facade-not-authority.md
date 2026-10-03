# ADR-005 — Compatibility Façade Is Not an Authority

## Status
Accepted proposal

## Decision

`NativeLanguageModels`는 Apple-shaped API convenience를 제공할 수 있지만 별도 runtime/state owner가 되지 않는다.

```text
NativeLanguageModels
       ↓
LanguageModelRuntime
       ↓
LanguageModelCore
```

## Rejected

- duplicate transcript authority
- duplicate task lifecycle owner
- duplicate resident model cache
- Agent state ownership

## Rationale

Compatibility는 API 문제이고 authority는 runtime 설계 문제다. 둘을 결합하지 않는다.
