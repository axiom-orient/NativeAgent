# AppleLocalAILEAP

AppleLocalAI용 선택 LEAP package다. Text `LanguageModel` adapter와 별도 audio runtime을 제공하며 upstream `LeapSDK` binary declaration은 `NativeAgent/Packages/NativeAILeapSDK` 한 곳을 공유한다.

Package/binary identity 공유와 runtime resident ownership은 다른 문제다. Standalone AppleLocalAILEAP runtime은 자신의 load/unload contract를 따르고, NativeAgent와 같은 model resident를 공유하려면 workspace `LocalBackend` composition을 사용한다.

실기기에서는 [`../../scripts/sign-leap-embedded.sh`](../../scripts/sign-leap-embedded.sh)와 app signing 설정을 포함해 dyld/runtime을 검증한다. manifest resolution만으로 physical-device 성공을 주장하지 않는다.
