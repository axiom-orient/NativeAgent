# Host qualification 절차

이 문서는 SDK를 실제 consumer 환경에서 qualification할 때의 범위와 증거 형식을 정의한다. 현재 source·환경별 machine receipt는 workspace docs/verification/imported-baseline/production-refactor-20260920가 소유하며, [VERIFICATION](VERIFICATION.md)은 이 workspace에서 실행한 test/build 기록이다. 어느 쪽도 포함하지 않은 live behavior의 증거로 사용할 수 없다.

## 증거 단계

| 단계 | 확인 대상 | 이것만으로 증명하지 않는 것 |
|---|---|---|
| Source audit/archive | 배포 inventory, manifest, attribution와 archive integrity | compile 또는 runtime 동작 |
| Build | 명시된 OS/toolchain에서 public products compile | test 결과와 external effect |
| Package tests | package가 직접 시험하는 contracts | 실제 OS/account/device/peer 동작 |
| Consumer qualification | 독립 앱·계정·권한·기기에서의 입출력과 lifecycle | 다른 source revision이나 미시험 environment |
| Recovery test | 실제 interruption 뒤 read-back, reconciliation과 reopen | power loss/hardware semantics를 포함하지 않은 한 그 보장 |

Mock/scripted transport와 fixture는 내부 contract 증거다. 같은-process object 재생성은 process-death 증거가 아니다. PASS는 기록된 source, command와 environment 범위에만 적용한다.

## 실행 범위

Core consumer는 run/send, approval, tool/artifact publication, wait/cancel, process reopen, pending effect reconciliation과 format-specific recovery를 확인한다. 선택 capability는 독립 범위로 유지한다.

- ChatGPT: explicit sign-in/refresh, text/stream/tools, image generate/edit, response read-back와 cancellation.
- FoundationModels: available/unavailable, generation, cancel와 session reuse.
- MLX/LEAP/LiteRT: dependency resolution, artifact preparation, load/run/cancel/drain/unload/reload.
- MCP: 실제 stdio/HTTP peer, auth, cancellation과 reconnect.
- Browser/OS tools: host callback, OS permission, navigation/read-back과 cancellation.
- App Group/external writer: signed multiple process, competing writes, kill/relaunch와 recovery.

기기 harness와 외부 account/peer는 해당 package의 README·Xcode project와 public API를 사용한다. [LEAP 음성 실기기 절차](../../../Providers/LEAP/DeviceQualification/README.md)와 [MCP qualification harness](../Packages/NativeAgentMCP/Qualification/README.md)가 package-specific entrypoint 예다.

## Receipt

각 qualification은 source/archive 또는 surface digest, subject/check, toolchain·OS·device, model revision, account/peer 종류, exact command, exit status, 원본 log와 observable result를 보존한다. Secret, token과 불필요한 개인 데이터는 기록하지 않는다. Source 변경 후 이전 PASS를 자동 승계하지 않는다. archive CRC는 runtime evidence가 아니다. 옛 release.py는 활성 배포 도구가 아니다.

로컬 실행은 source 밖의 새 build/evidence directory를 쓰고, 각 실행에 새 evidence label을 사용한다. Process 종료 상태가 중요한 live/device test는 scripts/verify_local.py로 실행해 timeout과 process custody를 기록할 수 있다. Live account test는 quota를 사용할 수 있으므로 account와 effect를 host가 명시적으로 선택한다. 실계정·기기·peer가 없는 환경에서는 반복 실행으로 PASS를 만들지 않는다.
