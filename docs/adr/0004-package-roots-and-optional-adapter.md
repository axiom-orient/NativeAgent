# ADR-0004 — 실제 SDK 루트와 선택형 adapter

- 날짜: 2026-09-20
- 상태: 채택·구조 적용. Apple runtime qualification은 별도.

## 문제

NativeAgent 폴더 자체에는 manifest가 없고 실제 kernel package가 세 단계 아래에 있었다.
루트 Integrations에는 production adapter와 검증용 package가 함께 있어 SDK 소비 경계가 흐려졌다.

## 결정

NativeAgent의 기존 package는 `Agent/NativeAgentPackage/`에 둔다. core/runtime 및 선택 provider의 독립 manifest는 유지한다.
AppleLocalAI root는 NativeAgent를 강제 의존하지 않는다.
기존 adapter는 `MigrationHold/AppleLocalAI/Packages/NativeAgentProviderAppleLocalAI`로 이동하며 공개 이름을 유지한다.
검증 소비자는 각 SDK의 Qualification에 둔다. 전체 앱 조립은 소비 앱이 소유한다.
ASK는 `Knowledge/ASK/`에 독립 구현을 보존한다. 새 umbrella package·manager·server를 만들지 않는다.

## 결과

활성 Agent와 보존된 AppleLocalAI root를 구분해 선택한다. 보존 API는 현재 native qualification 완료나 활성 dependency가 아니다. optional adapter를 쓰지 않는 소비자에게 SDK 의존성을 추가하지 않는다.
기존 source·API·resource를 바꾸지 않고 package 경로와 관리용 검사·문서를 갱신한다.
배포 검사에 root manifest·root source hash·올바른 root 의존·root 밖 escape 거부 회귀 테스트를 추가한다.
현재 배포 루트와 과거 이동의 이름을 구분했다. 자세한 설치 및 한계는 [PACKAGING](../PACKAGING.md)을 따른다.
