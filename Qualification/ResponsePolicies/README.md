# 실제 응답·내구성 검증

`ResponsePolicyQualification`은 기존 다국어·캐릭터 응답 관찰 도구다. `DurableLiveQualification`은 실제 FoundationModels를 사용하는 AgentManager의 생성·중단·재열기를 검증한다. macOS 26 이상과 사용 가능한 Apple Intelligence가 필요하며 실계정 자격증명을 읽지 않는다.

저장소 root에서 아래 명령을 실행한다. supervisor의 작업 디렉터리는 `Agent`이며, scratch와 evidence는 저장소 밖의 새 경로여야 한다.

```sh
python3 Agent/scripts/verify_local.py --evidence $TMPDIR/native-proof --label build --timeout 180 -- \
  swift build --package-path Qualification/ResponsePolicies \
  --scratch-path $TMPDIR/native-proof/build --product DurableLiveQualification --jobs 4 -Xswiftc -warnings-as-errors
python3 Agent/scripts/verify_local.py --evidence $TMPDIR/native-proof --label lifecycle --timeout 180 -- \
  env NATIVEAGENT_LIVE_FOUNDATION=1 python3 Qualification/ResponsePolicies/check_durable_lifecycle.py \
  $TMPDIR/native-proof/build/debug/DurableLiveQualification $TMPDIR/native-proof/new-data
```

첫 프로세스가 실제 모델 응답을 저장한다. 두 번째 프로세스의 첫 실제 delta에서 테스트 observer가 정지 신호를 보내면 parent가 정확한 자식 handle을 SIGKILL하고 회수한다. 제3의 프로세스는 저장된 전체 메시지 prefix를 비교하고, running 세션의 재개가 같은 started 영수증을 복구 대기로 전환하는지 확인한다. 그 시점의 provider 시작 이벤트와 delta는 0이어야 한다. 이후 명시적 `.retry` 결정으로 실제 모델 호출을 완료한다. SDK에 crash hook을 추가하지 않는다.

`process-custody.json`, `interrupted-readback.json`, `expected.json`, `reopened.json`과 각 단계 로그가 실제 파일·영수증·프로세스 증거다. 데이터는 합성이며 검증 후에도 증거 경로에 남긴다. OS 모델 서비스 자체의 내부 작업, 전원 손실, 실제 기기나 cloud provider의 복구를 증명하지 않는다.
