# LiteRT 실기기 검증

실제 iPhone에서 현재 source가 고정한 CPU C API 0.17.0을 검증하는 절차다. 이번 Linux 환경에서는 실행하지 않았다. Simulator나 scripted client는 이 검사를 대신하지 않는다.

1. `litert-community/Qwen3.5-0.8B`의 revision `c23b16e43ada6ead533b12593fe500bbe268014f`에서 `Qwen3.5-0.8B_int8.litertlm`을 별도 디렉터리에 준비한다.
2. SHA-256 `684d4d34adf7176eb47f6026ff65c33d42584737254e5524a8d1ad62edc21b98`, 크기 `963184864` bytes를 확인한다.
3. 저장소 루트에서 `LITERT_MODEL_DIR=/absolute/model-directory xcodegen generate --spec Providers/LiteRT/DeviceQualification/project.yml`을 실행한다.
4. `xcodebuild test -project Providers/LiteRT/DeviceQualification/LiteRTQualification.xcodeproj -scheme LiteRTQualification -destination 'platform=iOS,id=YOUR_UDID' DEVELOPMENT_TEAM=YOUR_TEAM -allowProvisioningUpdates`를 `Agent/NativeAgentPackage/scripts/verify_local.py`의 bounded 실행으로 감싼다.

검사는 기본 생성, JSON 값, 대화 이력, 생성 중 취소, 기존 엔진 거부, shutdown, 새 runtime 로딩 후 재생성을 확인한다. `sampling: .greedy`를 명시한다. 취소 후 같은 엔진을 재사용하지 않는다. 기본 설정 `.modelDefault`는 아티팩트의 샘플링 설정을 보존한다.

이 아티팩트는 도구 템플릿이 없다. 도구 지원은 `supportsToolCalls: false`이며 도구 요청의 사전 거부를 확인한다. **이 검사는 실제 도구 실행 성공을 의미하지 않는다.** 검증된 다른 아티팩트를 호스트가 제공할 때만 `supportsToolCalls: true`로 등록한다. Qwen3.5 원본 XML 도구 형식과 선택한 LiteRT Qwen JSON 파서의 호환성은 고정 binary에서 별도 검증해야 한다.

모델과 로컬 경로를 포함하는 생성 Xcode 프로젝트는 배포 소스에 넣지 않는다. 결과 로그와 xcresult도 저장소 밖에 보존한다.
