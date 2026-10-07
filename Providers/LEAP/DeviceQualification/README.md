# LEAP 음성 실기기 검증

실제 iPhone에서 고정 `LeapVoiceModel.pinned`를 import하고 TTS → ASR → speech-to-speech를 실행한다. QAD1.2 텍스트 모델과 별개의 음성 아티팩트다.

- 저장소: `LiquidAI/LFM2.5-Audio-1.5B-GGUF-LEAP`
- revision: `d78ca1db4adae8be7a7dbab003d128abdb5b94c6`
- 파일: `LFM2.5-Audio-1.5B-Q4_0.gguf`, `mmproj-LFM2.5-Audio-1.5B-Q4_0.gguf`, `vocoder-LFM2.5-Audio-1.5B-Q4_0.gguf`
- import가 provider의 고정 manifest 크기·SHA를 검증한다. 모델은 저장소 외부에 둔다.

저장소 루트에서:

```sh
LEAP_VOICE_MODEL_DIR=/absolute/voice-directory xcodegen generate --spec Providers/LEAP/DeviceQualification/project.yml
```

생성된 `LeapQualification.xcodeproj`의 `LeapQualification` scheme을 실제 기기 destination과 자신의 `DEVELOPMENT_TEAM`으로 `xcodebuild test`한다. `Agent/NativeAgentPackage/scripts/verify_local.py`로 timeout과 프로세스 회수를 기록한다. LEAP 0.11의 `LeapSDK`와 `inference_engine`은 형제 framework로 SwiftPM이 각각 embed/sign한다.

합성 문장의 유한·비영 PCM, ASR 핵심 단어, S2S 텍스트·PCM 완료와 unload를 검증한다. 마이크와 개인 녹음은 사용하지 않는다. 사람의 청취 품질 평가는 포함하지 않는다. 생성 프로젝트·모델·로그는 배포 소스에 포함하지 않는다.

추가 취소 시험 `testVoiceCancellationDrainsAndReloads`는 실제 PCM 수신 후 consumer를 취소하고, native drain/unload를 기다린 뒤 명시 reload와 새 TTS 완료를 확인한다. 실행 범위와 receipt는 [Agent qualification 절차](../../../Agent/NativeAgentPackage/docs/QUALIFICATION.md)에 기록한다.

소비 Task 취소 시 AsyncThrowingStream iteration은 오류 없이 끝날 수 있다. 검증 consumer는 iteration 뒤 Task.checkCancellation을 확인하고, native owner의 unload를 join한 뒤 재로드한다. 이는 native 종료와 consumer 취소를 구분하는 현재 계약이다.
