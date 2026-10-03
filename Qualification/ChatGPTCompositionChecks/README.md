# ChatGPTCompositionChecks

분리된 실제 Account·Text·Image·Text adapter·Image capability를 함께 검사하는 **test-only package**입니다. production library/executable product는 없으며 서비스들이 이 package를 의존하지 않습니다.

구형 두 package의 테스트 19개 파일을 소유 경계에 맞게 이동했습니다. 기존 assertions는 유지하고 import 및 raw Image-owned payload 사용만 조정했습니다. 계정 epoch/cache/authorization origin/공백 image intent 회귀와 별도 wire 경계 검사를 추가했습니다. fixture는 production transport/Keychain/계정·이미지 성공 증거가 아닙니다.

```sh
# workspace root; CryptoKit/Security/Network/NaturalLanguage/Apple image SDK 필요
swift test --package-path NativeAgent/Qualification/ChatGPTCompositionChecks
```

전체 suite는 이번 Linux 환경에서 **NOT_RUN**입니다. `tools/verify-chatgpt-wire.py`는 그중 portable metadata/SSE/image codec와 bounded transport의 실제 선택 source만 따로 컴파일합니다. Account actor, Keychain, callback, Text/Image client 전체, native image raster·AgentManager는 그 portable 범위에 포함되지 않습니다.

실계정 검사는 기존 `ChatGPTLiveIntegrationTests`의 명시 환경 opt-in을 유지합니다. token/namespace를 자동 탐색하거나 credentials를 source/로그에 추가하지 않습니다. 현재 로그인 상태·특정 live model 제공 여부는 UNKNOWN입니다.

[workspace 검증](../../docs/verification/README.md) · [Current](../../docs/IMPLEMENTATION_STATUS.md) · [API 이동](../../docs/adr/0003-split-chatgpt-text-image.md)
