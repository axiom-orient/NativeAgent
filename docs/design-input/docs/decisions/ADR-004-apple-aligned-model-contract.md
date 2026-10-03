# ADR-004 — Apple-Aligned Model Contract on iOS 17+

## Status
Accepted proposal

## Context

iOS 27 Foundation Models는 `LanguageModel`과 `LanguageModelExecutor`를 통해 local/server model provider를 하나의 session API로 수렴시킨다. NativeAI는 iOS 17+를 지원해야 한다.

## Decision

NativeAI의 iOS 17+ model core를 Apple 구조와 semantic alignment한다.

- lightweight model descriptor
- explicit capabilities
- hashable/sendable executor configuration
- executor-owned generation mechanism
- runtime/session-owned request context

단 Apple framework type 자체를 core dependency로 사용하지 않는다.

## Consequences

Positive:

- iOS 17→27 migration cost 감소
- provider 구조 일관성
- Apple bridge 단순화

Negative:

- Apple API와 독립 contract의 mapping 유지 필요
- exact source parity는 별도 비용
