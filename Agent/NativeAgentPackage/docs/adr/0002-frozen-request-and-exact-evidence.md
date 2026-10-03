# ADR-0002 — 요청 확정 경계와 exact indexed evidence

## 상태

**Accepted — 2026-09-11, 이번 보강 범위의 구현 결정.** Core release 승인이나 ASK 라이선스 결정은 아니다.

## 맥락

MemoryModelClient는 ledger 결정 후 입력을 바꿀 수 있지만 repository의 소비자는 standalone 테스트이며 public product 자체는 유효하다. 기존 broad evidence는 pathless/unknown을 허용해 탐색에는 유용하나 grounded answer의 exact reference를 보장하지 않는다. 기존 SourceIndex history와 request ledger는 이미 독립 authority를 가진다.

## 결정

새 pre-ledger memory subsystem을 만들지 않는다. standalone MemoryModelClient를 보존하고 ModelRuntime admission에서 조합을 거부한다. first-party routing은 base 제한을 전파한다. Consensus의 기존 명시 aggregate route는 동등한 입력을 여러 child operation으로 처리하는 별도 계약이므로 일괄 삭제하지 않는다. aggregate 품질/child attribution은 optional qualification이다.

ASK는 기존 SourceIndexStore의 history를 재사용하고 immutable reference와 resolve/buildGroundedPack을 제공한다. 기본 currentSource는 ok만 허용한다. caller가 retainedIndexedContent를 명시하면 retained indexed representation을 검증해 반환하지만 original freshness를 그대로 유지한다. borrowed raw의 소유권을 발명하지 않는다. 명시 index delete는 기존 history purge 계약을 유지한다.

Core와 optional qualification은 새 package split이 아니라 release 판정 범위로 분리한다. 기존 allowlist/라이선스/외부 고지는 약화하지 않는다.

## 결과

MemoryModelClient를 직접 ModelRuntime에 넣던 외부 caller는 명시 configuration error를 받는다. 이는 정확한 복구 계약을 보호하기 위한 제한이며 standalone API 삭제가 아니다. ASKQuery/ASKQueryResult의 additive case는 외부 exhaustive switch 갱신을 요구할 수 있다. 기존 broad API·ledger lookup·payload reader·DB schema·manifest/pin은 유지한다. 원래 source parser와 Apple/실제 provider 실행을 대체하는 stub은 도입하지 않는다.
