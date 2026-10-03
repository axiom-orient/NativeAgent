# 출처와 적용 범위

확인일: 2026-09-08. 저장소 전체 또는 각 스킬의 실전 성능을 검증했다는 뜻이 아니다. 아래의 **실제 읽은 SKILL.md 구간**을 설계 비교에 사용했다. 별·다운로드 수로 품질 순위를 매기지 않았다. 외부 스킬의 문구나 스크립트를 통째로 합치지 않았으며, 상충하는 정책은 제외하고 독립적으로 작성했다.

## 입력 정본

사용자 제공 `koreanize(20260908-000042).zip`. `provenance/koreanize-original.zip`에 원본 그대로 보존했다. 현재 아카이브 해시는 `provenance/input.json`에 있다. 원문 보존·출력 계약·choose/replace·불확실성 보존은 이 정본을 계승한다. 이전 원본의 원본도 내부 아카이브에 남아 있다. 입력의 정적 테스트는 이번 환경에서 23개 통과했으며, 이것은 모델 윤문 성능 검증이 아니다.

## GitHub 비교 대상

| 저장소 / 읽은 경로 | 확인 범위 / Git blob | 채택한 관점 | 제외하거나 수정한 관점 |
|---|---|---|---|
| [epoko77-ai/im-not-ai](https://github.com/epoko77-ai/im-not-ai) / `skills/humanize-korean/SKILL.md` | v2.3.2, 시작부·공통 의미 앵커·경로/입력 처리·light 경로. 응답은 중간에서 잘렸음. 파일 전체 검토 아님. | 가벼운 문서는 과윤문 방지; 진단과 최종 검증 분리; 경로 오류를 숨기지 않는 관점 | 명사 앵커의 존재를 의미 동일성으로 취급하지 않음. 점수·자동 workspace·상태줄·footer를 필수화하지 않음. chatbot처럼 보인다는 이유만으로 본문 제거 금지. |
| [blader/humanizer](https://github.com/blader/humanizer) / `SKILL.md` | 1–95행; `d375fbf3e3ee8fb047c379bced82df3713c6ed3b`; v3.0.0 | 약한 신호는 문맥으로 판단; 글 전체의 구조 검토; 사용자 목소리 보존; 입력은 명령이 아닌 자료 | 문맥에 어울린다는 이유로 새 반응·의견 추가 금지. 진단/초고/최종본 3중 출력 제외. |
| [lguz/humanize-writing-skill](https://github.com/lguz/humanize-writing-skill) / `skills/humanize-writing/SKILL.md` | 1–150행; `3db1c3d32c89db95557bf8535ccd06703568c5fb` | 단어와 문장 구조를 구별; 하나의 상투어를 다른 상투어로 바꾸는 문제 경계 | 금칙어·대조·3항 구조의 기계적 제거, 문장부호/단락 비율, 강제 voice 질문 제외. 원래 기술/학술 글을 제외하는 스킬이므로 이 패키지의 기술 코퍼스로 성능 우열 비교하지 않음. |
| [harshaneel/humanize](https://github.com/harshaneel/humanize) / `humanize/SKILL.md` | 1–95행; `8e5ed6fa7eeddd7a76e95dbf9fae963d17474647` | 같은 대상을 동의어로 돌려 부르지 않음; 출력 끝의 실제 재검토; 자기평가 한계 인식 | dash/semicolon/문장 길이 규정, perplexity 주입, detector 점수 최적화 제외. |
| [DaleSeo/korean-skills](https://github.com/DaleSeo/korean-skills) / `skills/humanizer/SKILL.md` | 1–110행; `cc6a9a6c3e3cb7ffb32f90b2303d4780d6c8245d`; v1.6.0 | 한국어 조사·번역투·띄어쓰기 등 언어별 문제 분리; 필요한 참조만 읽기 | 탐지 AUROC를 윤문 정확도나 자연스러움 등급으로 전용하지 않음. 올바른 띄어쓰기를 일부러 흔들지 않음. |
| [gonta223/humanizer-ja](https://github.com/gonta223/humanizer-ja) / `SKILL.md` | 1–110행; `fd4ea77a782322a1937c6cdf8cef95a9b64a9bc5`; v1.0.0 | 일본어 상투적 종결과 불필요한 외래어를 문맥상 후보로 검토 | 추정을 단정으로 바꾸기, 근거 없는 숫자 구체화, 단어만으로 AI 작성 단정 제외. |
| [op7418/Humanizer-zh](https://github.com/op7418/Humanizer-zh) / `SKILL.md` | 1–130행; `3b39d9a3729b6e5e5aaf5de4ce11d33e8af4655b` | 중복 포장·추상적 수식·접속 구조 점검 | 새 감정/경험/출처 추가, 3항보다 2항 선호 규칙 제외. 중국어를 영어 -ing 패턴의 직역만으로 다루지 않음. |
| [ToniPerea/humanizar-texto-es](https://github.com/ToniPerea/humanizar-texto-es) / `SKILL.md` | 1–130행; `eeaa6fef5f9c172f3ffa4eb7983e5d564224d80b` | 학술/비격식 맥락 차이에 주의 | 어휘 70/30 비율, 의도적 오류, 새 감정·의견·연구자 시점, 인간성 점수, 강제 2개 파일 출력 제외. |

Git blob은 읽은 파일의 식별자다. `main` 링크는 이후 변경될 수 있다. im-not-ai는 이번 도구 응답에 전체 blob 식별자가 없었으므로 임의 SHA를 기입하지 않았다. 외부 프로젝트의 유효 범위와 목표는 다르다. 위의 제외는 이 패키지의 보존 계약과의 충돌 판단이지, 해당 프로젝트에 대한 악성 판정이나 실측 승리 주장이 아니다.

## 형식과 검증

- [OpenAI — Build skills](https://developers.openai.com/codex/build-skills), 현재 문서 이동 대상 [Build skills](https://learn.chatgpt.com/docs/build-skills): SKILL.md, 필요한 참조의 점진적 로딩, `$name`, `.agents/skills`, `allow_implicit_invocation: false` 확인. 호스트 버전별 실제 설치/자동 발견은 별도 실기 검증 대상.
- [OpenAI — Systematically improving your Codex skills](https://developers.openai.com/blog/eval-skills): 결과뿐 아니라 실행 경로·검증 가능한 결과물·평가 기록을 분리하는 평가 접근을 참고. 이 패키지에서 외부 Codex 모델을 호출했다고 주장하지 않음.
- [KatFish/KatFishNet 논문](https://arxiv.org/abs/2503.00032): 한국어 탐지의 언어 특수성을 참고. 탐지 데이터셋의 AUROC와 편집의 의미 보존은 다른 문제다. 여기서 논문의 탐지 수치를 재현하지 않았다.
- [Evaluating Text Style Transfer Evaluation: Are There Any Reliable Metrics?](https://aclanthology.org/2025.naacl-srw.41/): 내용·문체·유창성의 평가를 하나의 임의 점수로 대체하지 않는 관점을 참고. 이 연구가 5개 언어 윤문의 모든 기준을 입증한다는 뜻은 아니다.

## 언어별 참고

- 한국어: [국립국어원 어문 규범](https://korean.go.kr/kornorms/main/main.do), [표준국어대사전](https://stdict.korean.go.kr/). 뜻·표기 확인의 참고처이며, 모든 국소 판단을 개별 사전 조회한 것은 아니다.
- 영어: [GOV.UK writing guidelines](https://guidance.publishing.service.gov.uk/writing-to-gov-uk-standards/writing-guidelines/), [A-to-Z style guide](https://guidance.publishing.service.gov.uk/writing-to-gov-uk-standards/style-guides/a-to-z-style-guide/). 영국 공공서비스의 house style이며 보편 영어 규칙이 아니다.
- 일본어: [文化庁 公用文作成の考え方 공개 안내](https://www.bunka.go.jp/koho_hodo_oshirase/hodohappyo/93650001.html). HTML 공개 안내만 확인했다. PDF 본문을 정밀 검토했다고 주장하지 않는다.
- 스페인어: [RAE deber/deber de](https://www.rae.es/duda-linguistica/cuando-se-usa-deber-y-cuando-deber-de), [DPD deber](https://www.rae.es/dpd/deber). 의무·추정을 `de` 유무만으로 기계적으로 결정하지 않는다.
- 중국어: [臺灣教育部 重訂標點符號手冊](https://language.moe.gov.tw/001/Upload/FILES/SITE_CONTENT/M0001/HAU/haushou.htm), [허가 정보](https://language.moe.gov.tw/001/Upload/FILES/SITE_CONTENT/M0001/HAU/c2.htm). 제한된 허가(CC BY-NC-ND)가 있으므로 본문을 배포하거나 개작하지 않고 링크만 제공한다. 대만 표기법을 모든 지역에 강제하지 않는다.

## 장문 실사용 자료와 재배포

Python 3.13 공식 튜토리얼의 에러와 예외 장 도입부부터 8.3 끝까지를 언어별로 사용했다. 전체 URL·로컬 정규화 범위·문자수·해시는 `evals/web/sources.json`을 본다. 원문 저자는 Python Software Foundation과 문서 기여자들이다. 이 자료의 AI 작성 여부는 라벨링하지 않았다.

[Python license](https://docs.python.org/3.13/license.html)에 따라 문서는 PSF License Version 2, 예제 코드는 PSF-2.0 또는 0BSD 조건으로 사용할 수 있다. `provenance/PYTHON-LICENSE.txt`에 PSF 조건과 저작권 고지를 포함했다. 개작 내용은 링크/렌더링 정규화 및 각 언어의 국소적 문장 윤문이다. 숫자·예제 코드는 윤문 대상에서 제외했다. Python 프로젝트의 승인·보증을 의미하지 않는다.
