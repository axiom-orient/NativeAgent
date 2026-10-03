# CLiteRTLM 0.15.0 배포 근거

2026-09-10 GitHub 공식 [v0.15.0 release](https://github.com/google-ai-edge/LiteRT-LM/releases/tag/v0.15.0)의 자산을 확인했다. 이 폴더의 두 파일은 원본 그대로 보존했다.

| 자산 | SHA-256 |
|---|---|
| [CLiteRTLM.xcframework.zip](https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.15.0/CLiteRTLM.xcframework.zip) | `d6ccf6b54362d894ff71a7580c7e446d36767dab908aecfbb16ffca0fa0bc59b` |
| [CLiteRTLM.spdx.json](CLiteRTLM.spdx.json) | `29f73046b46883005a00cd52e8dba88bd32e4c3b5d8ba04b88d48ea4eab3d19b` |
| [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt) | `cbff17f4a653c07b4a13201927ab0fb46cc13e592485ee7fe4e2c1d1526ac52b` |

binary asset의 GitHub SHA-256이 [Package.swift](../Package.swift)의 binaryTarget checksum과 같다. SBOM/NOTICE는 같은 release의 공식 asset digest와 실제 다운로드 bytes를 대조했다. SPDX에는 142개 package가 기재되어 있다. per-file binary hash는 제공하지 않으므로 각 object file의 독립 재현 빌드나 완전한 license compliance 증명으로 확대하지 않는다.

원본: [SBOM](https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.15.0/CLiteRTLM.spdx.json), [NOTICE](https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.15.0/THIRD_PARTY_NOTICES.txt).
