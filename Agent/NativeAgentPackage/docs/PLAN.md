# Agent — PLAN

현재 구현의 다음 단계만 기록한다. 완료된 변경 이력은 이 문서에 누적하지 않는다.

## P1 — producer completion과 실제 Apple 환경 qualification

- Swift 6.4 + SDK 27에서 Agent, 선택 provider, integration package를 실제 manifest로 resolve/build/test한다.
- MLX·LEAP·LiteRT 각각에서 `load → generate → cancel/drain → reuse → shutdown`을 실제 모델로 검증한다.
- borrowed runtime 사용 중 Manager 작업 종료가 resident model을 해제하지 않고, host 종료만 최종 해제를 수행하는지 확인한다.
- late success, 중복 취소, 부분 load 실패, drain 실패를 실제 backend에서 확인한다.

## P1 — 선택 capability qualification

- [상위 P1 계획](../../../docs/PLAN.md)의 ChatGPT owned invocation/SSE/URLSession completion 연결의 full Apple qualification을 수행한다. wire test만으로 producer 종료를 인정하지 않는다. account/text/image의 실계정 흐름과 취소·재시도·sign-out 경계를 검증한다.
- Skills, File, Web, Browser, MCP의 permission / network / process failure를 각 adapter 경계에서 검증한다.
- Memory·Goals·Evolution·Consensus는 실제 consumer composition에서 state owner와 post-commit failure를 검증한다.

## P2 — 배포 경계

- release manifest와 source archive가 canonical source만 포함하고 generated/cache/과거 검증 residue를 포함하지 않는지 확인한다.
- 실제 앱에서 binary signing, model artifact placement, OS lifecycle, memory pressure를 qualification한다.

## 완료 기준

각 항목은 실제 source·실행 명령·환경·결과가 결속된 증거가 있을 때만 완료로 바꾼다. mock이나 임시 graph의 성공을 실제 provider/device 성공으로 승격하지 않는다.
