# AppleLocalAI — Specification

## Public contract

- `AppleLocalAIRequest`는 유효한 prompt를 표현한다.
- `AppleLocalAIProfile`은 model/instructions/tools/generation/history policy를 구성한다.
- `AppleLocalAISession`은 respond/stream/generated output/token-count APIs를 제공한다.
- session reconfiguration/reset/cancel은 active operation state를 일관되게 유지해야 한다.

## State rules

- 동시에 material operation을 둘 이상 active로 만들지 않는다.
- stale/late result는 현재 operation을 완료시키지 않는다.
- cancellation은 explicit state transition이며 성공 response로 변환하지 않는다.
- invalid prompt/profile은 native I/O 전에 거부한다.

## Optional package rules

- `AppleLocalAILocalModels`와 `AppleLocalAILEAP`는 root와 독립적으로 선택한다.
- optional package의 external dependency/OS requirement가 root consumer에 자동 전파되어서는 안 된다.
- model artifact admission과 model runtime lifetime을 구분한다.

## Shared runtime rules

NativeAgent integration에서는 Apple session/executor가 shared runtime을 unload하지 않는다. unsupported transcript/tool/metadata/options는 bridge에서 명시 거부한다.

## Evidence

Unit/pure tests, Apple SDK compile, vendor link, actual inference, physical device test는 별도 acceptance gate다.
