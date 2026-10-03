# NativeAI — PLAN

[Current](IMPLEMENTATION_STATUS.md), [구현 리뷰](production/IMPLEMENTATION_REVIEW.md), [Qualification](production/QUALIFICATION.md)이 기준이다. 구현 완료와 native 검증 완료를 분리한다. 새 backend로 검증을 우회하지 않는다.

## 이번 리팩토링에서 닫은 항목

ModelHub의 Hugging Face repository/revision syntax를 `HubRepositorySyntax` 하나의 owner로 수렴했다. Address와 ImportCandidate의 중복·불일치 validation을 제거하고, 공식 repo ID/Git ref 제한을 fail-closed로 적용했다. Candidate identity는 provider authority를 포함하고 artifact path를 UTF-8 length-prefix로 직렬화하여 delimiter collision을 제거했다. public type/function shape와 backend protocol은 유지했다.

변경 경로는 ModelHub 테스트 13개를 3회 반복하고 release build까지 `-warnings-as-errors`로 확인했다. Core 57 / Runtime 99 / Account 50 / Text 3 / Image 3과 NativeAgent target build도 다시 통과했다. `ModelArtifactStore`는 현재 Linux에 CryptoKit module이 없어 NOT_RUN이다. Apple SDK/device/live service gate는 아래 P0/P1에 그대로 남긴다.

## 이전 callback 리팩토링에서 구현한 항목

Callback I/O를 전용 serial queue로 옮겼다. accepted connection/I/O receipt의 pure ledger, stale/duplicate 방어, sticky drain failure를 연결했다. HTTP parser의 incomplete/invalid 혼동과 retry 정수 경계를 고쳤다. native socket 회귀를 Account leaf로 이관했다. 로컬 실행 결과는 [검증 정본](verification/README.md)을 따른다. **Apple에서의 compile/runtime는 아직 완료가 아니다.**

## P0 — 배포를 막는 남은 검증

| 작업 | 이미 구현·보존한 것 | 필요한 통과 증거 |
|---|---|---|
| Native callback completion | 전용 queue, listener/connection/I/O ledger, 한 번의 terminal, 실패 owner 보존 | Account `CallbackNativeTests` 실제 SDK compile/link/run; 성공·취소·timeout·잘못된 framing·8개 admission 초과·port conflict; accepted count 0과 재bind |
| Auth 전체 연결 | Account epoch/admission/refresh/signOut join, PKCE·등록 redirect, serialized Keychain I/O | 실제 beginSignIn→completeSignIn→cancel/signOut→relaunch; state 검증, token 저장 실패, late result, 실패한 drain 뒤 재사용 차단 |
| native provider별 qualification | 독립 pin, LocalBackend single owner, borrowed release | OS/device/artifact digest별 load→generate→cancel→settle→reuse→unload→reload |
| subscription 지원 계약·실계정 | frozen profile, 독립 Text/Image, API key 강제 전환 없음 | 지원/사용 권한 확인 뒤 승인된 계정의 text/image/error/cancel/quota; 그전까지 Experimental |
| 실제 iOS/macOS host | 공개 API, host scene/task/resident owner | cold launch/background/foreground/memory/logout/terminate/relaunch와 두 consumer 공유 |

Native `shutdownTimedOut`의 실제 발생/회복과 SDK callback ordering은 별도 미검증이다. pure ledger 통과만으로 이 gate를 닫지 않는다. 환경 부재는 같은 명령을 반복하지 않고 NOT_RUN으로 기록한다.

## P1 — 보안·내구성

Keychain synchronizable/AfterFirstUnlock의 여러 process/device rotation·복원·삭제 정책을 확인한다. 단일 actor를 전역 lock으로 해석하지 않는다. device-only 변경은 migration·보존·철회 계약을 먼저 확정한다.

ModelArtifactStore와 Agent의 실제 filesystem/process-kill/remote-outcome reconcile을 검증한다. stage/digest/atomic publish/lease/delete, unknown outcome 자동 replay 금지, diagnostic redaction·보존을 host까지 확인한다. 현재 변경을 이유로 credential/storage schema를 재작성하지 않는다.

ASKAgentTools/MCP는 실제 dependency resolution과 root/adapter/peer 통합 검증이 필요하다. 보존한 이전 하위 Knowledge 결과를 이번 root 통과로 승계하지 않는다.

## 조건부 후속·삭제 조건

OpenAI API backend, App Server, 추가 native provider, ASK repository 분리는 제품 요구가 확정된 경우만 진행한다. `.transparent` 요청 의도와 실제 alpha 결과는 별개다. provider/manifest pin을 임의 갱신하지 않는다.

MigrationHold와 optional/public surface는 dependency/import/caller/API parity/지원 consumer 증거가 있어야 제거한다. 과거 evidence는 imported-baseline으로 보존하며 현재 PASS와 혼합하지 않는다. correctness를 개선하지 않는 추가 추상화·wrapper·문서 복제는 만들지 않는다.
