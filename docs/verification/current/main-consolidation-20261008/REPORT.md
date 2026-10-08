# 메인 통합·레거시 폐기 검증 · 2026-10-08

현재 결과는 checks.json의 실제 명령·exit와 source-hashes.json의 입력을 따른다.
새 branch/PR/worktree 없이 main에 직접 통합한다. 이전 release/tag와 병합 PR 이력은 Git rollback 근거로 유지한다.
완료 PR 4개의 채팅 연결, 오래된 로컬 브랜치와 임시 복제본은 제거했다. 임시·중복 검증 파일은 배포 source에 포함하지 않는다.

## 변경과 폐기 계약

사용자가 최신 라이브러리 사용, 하위 버전 호환·마이그레이션 제거, 메인 직접 커밋·배포를 명시적으로 승인했다.
`retire-legacy-surface`의 preserve/retire/unknown 구분을 적용했다.

| 계약 | 상태 | 현재 경로·검증 |
|---|---|---|
| 네이티브 text/JSON/tool/cancel/drain/reload | preserve | 실제 MLX·LEAP 및 이전 고정 LiteRT 모델 실행. 추론을 fixture로 증명하지 않음 |
| EmbeddingGemma 2·MRL·batch·index·lease | preserve | CPU 네 차원에서 한국어 검색 8/8, 사용 중 삭제 거절·해제 후 삭제 |
| 저장 transaction·artifact custody·durable schema·credential bytes | preserve | 실제 SQLite/POSIX 테스트. 사용자 데이터/schema 변환 없음 |
| runtime owned/borrowed 수명 | preserve | acquireRuntime → ModelRuntimeAccess → release 하나의 acquisition 계약 |
| ModelClient generate-only 기본 stream | retire | provider의 stream 필수 구현. 내부 caller 갱신·구형 conformance compile 실패 |
| ChatGPTTransport stream-only 기본 invocation | retire | 실제 invocation/cancel/waitForCompletion 구현 필수·구형 conformance compile 실패 |
| connector/registry makeRuntime 호환 API·기본 ownership 추론 | retire | acquireRuntime만 제공. generic executor·실제 backend owner는 유지 |
| LEAP v1 cache/session 채택·MapKit placemark | retire | 현재 v2만 사용, location/address API. 이전 cache bytes는 변환·삭제하지 않음 |
| MigrationHold·이전 LiteRT module/version 분기 | retire | 앞선 메인에서 폐기. source guard와 최종 NOT_FOUND 검색 |
| 외부 사용자 정의 client/connector의 새 계약 채택 | unknown | 외부 코드 전체는 조회할 수 없음. 구형 API는 compile 실패하며 alias/migration 제공 없음 |
| 실계정·전체 OS 권한·host relaunch·전원 손실 | unknown | 이번 source 릴리스의 검증 범위 밖 |

이 contract의 source-only 폐기는 데이터 마이그레이션이 필요하지 않다. 외부 consumer에는 명시적 breaking change다.
ModelClientWithOwnedInvocation은 현재 독립 producer/native 수명을 표현하는 계약이며, library-version compatibility shim이 아니다.
ClientLanguageModel은 현재 descriptor/executor binding이다. 현재 schema, 정상 ISO8601 표현, 실제 지원 문서 형식도 유지한다.

## 최신 의존성

공식 GitHub release/tag를 2026-10-08에 재확인했다.

| 직접 의존성 | 현재 최신 |
|---|---|
| [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM/releases/tag/v0.18.0) | 0.18.0 |
| [MLX Swift](https://github.com/ml-explore/mlx-swift/releases/tag/0.32.3) | 0.32.3 |
| [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.32.3) | 3.32.3 |
| [LEAP](https://github.com/Liquid4All/leap-sdk/releases/tag/v0.11.0-SNAPSHOT) | 0.11.0-SNAPSHOT, upstream prerelease |
| [Hugging Face](https://github.com/huggingface/swift-huggingface/releases/tag/0.13.0) | 0.13.0 |
| [Transformers](https://github.com/huggingface/swift-transformers/releases/tag/1.3.4) | 1.3.4 |
| [Markdown](https://github.com/swiftlang/swift-markdown/releases/tag/0.9.0) | 0.9.0 |
| [SwiftMCP](https://github.com/axiom-orient/swiftMcp/releases/tag/0.4.2) | 0.4.2 |

Codex protocol 참조는 [rust-v0.161.0](https://github.com/openai/codex/releases/tag/rust-v0.161.0),
commit 979011409de0a60b52f179721948e65531d26144로 갱신했다. 공식 issuer/client ID/originator/callback/backend 주소를 대조했다.
기존 Credential schema와 service endpoint는 유지한다. 이는 실계정 서비스 호환 인증이 아니다.

간접 의존성 세 개는 최신 SDK의 실제 manifest 제약 때문에 유지한다:
Swift Crypto 4.5.2는 Hugging Face/Transformers의 <5.0.0,
SwiftSyntax 603.0.2는 MLX LM의 <604.0.0,
yyjson 0.12.0은 Transformers의 exact pin이다.
최신 5.0.0/604.0.0/0.13.0을 선택하려면 upstream 계약 변경이 필요하다. 해결됐다고 표시하거나 vendor source를 몰래 수정하지 않았다.
다른 간접 release와 추적된 lock도 재확인했다. 빌드 캐시의 과거 pin은 배포 source inventory에 포함하지 않는다.

## 실행과 실패 수정

Agent 완료/continuation은 응답·receipt·완료 상태를 한 transaction으로 저장한다.
SQLite 파일 생성권, artifact fsync/dedup, LEAP 설치/catalog와 늦은 callback의 작업 ID를 보강했다.
Context/Memory/Tutor/HWP/PDF 입력 한도·overflow·정리 실패를 검증한다.

WebKit의 nil snapshot configuration은 최신 SDK에서 다음 presentation을 기다릴 수 있다.
화면에 부착되지 않은 view는 명시적으로 기다리지 않게 하고, timeout/cancel/native callback의 operation ID를 검증한다.
실제 PNG의 배경 픽셀과 취소된 이전 callback이 다음 요청을 완료하지 못하는 회귀를 확인했다.
[공식 WebKit 구현](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm)과 실제 iOS/macOS 관측을 대조했다.

이미지 artifact 입력은 디렉터리 traversal 후 현재 소유한 descriptor를 닫도록 수정했다.
초기 종합 검사에서 EBADF 3건을 재현했으며 기존 파일·digest·symlink·FIFO 및 실제 image effect 합성 회귀로 검증한다.

macOS leaf minimum은 실제 Network Sendable/EventKit API와 dependency에 맞춰 14로 선언한다.
root 배포의 macOS 26/iOS 26.5 minimum과 최신 native binary checksum은 유지한다.
SwiftPM host 검증은 현재 기본 build system을 사용한다. 이전 deprecated build-system 옵션을 source runner에서 제거했다.

LEAP의 영구 process poison 회귀는 다른 테스트를 보호하도록 별도 native test process에서 실행한다.
49 XCTest + 13 Swift Testing과 poison XCTest 1개 모두 실제 동일 source를 사용했다. production guard를 reset하거나 완화하지 않았다.
초기 실패와 재현 로그는 저장소 밖 검증 디렉터리에 유지하며 최종 PASS와 구분한다.

## 한계

실제 inference는 고정 artifact·OS·모델·fixture corpus에 한정한다. 일반 검색 품질·모든 모델 지원·실계정·전체 host lifecycle의 PASS가 아니다.
전체 상용 G4/G5/G6 gate는 별도다. 이번 게시물은 검증한 source revision의 수동 SwiftPM/ZIP 릴리스다.
