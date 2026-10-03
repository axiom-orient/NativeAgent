# NativeAgent Verification

이번 리뉴얼의 실제 결과는 [workspace verification](../../../docs/verification/README.md)이 소유한다.
NativeAgent actual kernel target build와 exact-source kernel tests는 PASS이며,
Manager/Apple-only/full package/device/account는 동일한 성공 범위가 아니다.

묶음 루트에서:

```sh
python3 tools/verify-portable.py
python3 tools/verify-native-kernel.py
python3 tools/check-boundaries.py
```

전체 package test는 NaturalLanguage 등 Apple framework가 제공되는 환경에서
`swift test --package-path Agent/NativeAgentPackage`로 별도 실행한다.
실제 consumer의 범위/receipt는 [QUALIFICATION](QUALIFICATION.md)을 따른다.
