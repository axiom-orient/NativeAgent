> 이 ADR의 배포 세부는 이행 보류된 과거 기록이다. 현재 배포는 workspace PACKAGING을 따른다.

# ADR 001 — 실행 권위·선택 기능·source 배포의 분리

**상태:** ACCEPTED — 첨부에 존재한 명시 계약과 구현 경계를 통합한 기록. 새로운 제품 결정·작업 권한을 부여하지 않는다.

## 맥락

Agent identity·session/effect, 한 모델 invocation, native weight residency, 계정 credential은 서로 다른 수명과 책임을 갖는다. 같은 workspace에 여러 provider와 Labs 제품이 있다고 모두 기본 kernel에 결합하면 권한·실패·배포 기준이 섞인다.

기존 public manifest와 release configuration은 provider-independent kernel, opt-in 제품, sealed source workspace 배포를 명시한다. managed context는 작은 curated 파일을 기본으로 하고 advanced memory는 별도 제품이다.

## 결정

ModelCore는 공통 값/한도, ModelRuntime은 transient invocation, Agent는 durable session/effect, Manager는 identity/composition, host/provider runtime은 native resident를 소유한다. LEAP/MLX의 작업 wrapper는 borrowed이며 종료가 shared resident unload 권한을 갖지 않는다.

모델/Skill 가시성과 도구 실행 권한을 분리한다. 선택 기능은 공개 계약을 보존하되 최소 kernel의 필수 dependency로 편입하지 않는다. 기본 curated memory와 advanced MemoryProjection의 owner를 합치지 않는다.

배포 계약은 release/surfaces.json의 sealed source workspace와 local sibling dependencies다. 원격 SCM/registry identity·새 version scheme은 이 결정에 포함되지 않는다. stable kernel, qualification-gated provider, experimental Labs의 외부 검증 범위를 구분한다.

## 결과

Host는 명시적으로 provider·capability·권한·lifecycle를 연결해야 한다. wrapper 완료, archive integrity, live provider qualification은 서로 대체할 수 없다. optional public API를 제거하는 근거로 default 미사용만을 사용하지 않는다.

Skill 외부/multi-process writer 지원, 새로운 tool/schema 지원, 원격 배포는 이 기록의 승인 범위가 아니다. Domain의 현재 배포 분류는 release/surfaces.json이 소유하며 미결정 계획으로 중복 기록하지 않는다. 각 package의 manifest와 qualification receipt가 배포·실행 범위를 소유한다.

## 근거

[공개 제품과 target](../../Package.swift), [Runtime](../../../../Model/LanguageModelRuntime/Sources/LanguageModelRuntime/ModelRuntime.swift), [Manager](../../Sources/NativeAgentManager/AgentManager.swift), [MLX borrowed wrapper](../../../../Providers/MLX/Sources/MLXProvider/Runtime.swift), [LEAP borrowed wrapper](../../../../Providers/LEAP/Sources/LEAPProvider/Runtime.swift), [현재 배포](../../../../docs/PACKAGING.md), [qualification](../QUALIFICATION.md).
