# AppleLocalAI — Plan

1. Swift 6.4+/SDK 27에서 root package와 optional packages를 실제 resolve/build/test한다.
2. System/PCC/custom `LanguageModel` session semantics와 cancellation을 실제 Apple runtime에서 확인한다.
3. CoreAI/MLX/LiteRT/LEAP 각각 실제 model load/inference/unload를 검증한다.
4. LEAP physical-device signing과 audio/text resource lifetime을 검증한다.
5. consumer 요구가 확인된 capability만 추가한다. shared NativeAgent runtime의 owner는 workspace `LocalBackend` 규칙을 유지한다.
