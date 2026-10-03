# 독립 MCP peer 검증

공식 TypeScript SDK `@modelcontextprotocol/server` 2.0.0과 Swift bridge 0.4.1 사이의 실제 프로세스·파일 I/O 검사다. 합성 bearer 토큰은 로컬 테스트 전용이며 사용자 인증정보가 아니다.

이 디렉터리에서 `npm ci`와 `swift build`를 실행한다. 설치물과 Swift build는 저장소 밖의 scratch 경로를 권장한다. Node의 절대 실행 파일 경로를 제공한다. transport는 비어 있는 자식 환경에서도 동작해야 하며 사용자 환경변수 전체를 전달하지 않는다.

`Probe /absolute/path/to/node /absolute/path/peer.mjs /absolute/fresh-proof-directory`는 다음을 확인한다.

- 실제 도구 탐색과 파일 쓰기·읽기
- peer가 abort listener를 등록한 뒤 보내는 준비 신호
- 취소 알림 수신과 취소 후 재사용
- peer exit 42가 오류로 전달됨
- 호스트가 새 transport를 만들어 명시적으로 재연결함
- 모든 transport shutdown

`http.mjs /absolute/fresh-proof-directory`는 loopback 임의 포트에 서버를 열고 `port`를 기록한다. `AuthProbe http://127.0.0.1:PORT/mcp`가 토큰 없음·잘못된 토큰의 401과 `WWW-Authenticate` 보존, 올바른 토큰의 탐색을 검사한다. `requests.log`의 invalid가 정확히 두 번인지 확인한다. 서버는 검사 종료 시 SIGTERM 후 반드시 wait/reap한다. `scripts/verify_local.py`의 동일 process-group 안에서 서버와 클라이언트를 실행한다.

OAuth 로그인·갱신이나 임의 vendor 서버 호환성은 이 검사 범위가 아니다. `Sources/Peer`는 이전 동일 Swift SDK 상호 운용 비교용 peer이며 독립 vendor 증거로 세지 않는다.

`check_http.py /absolute/node /absolute/http.mjs /absolute/AuthProbe /absolute/new-evidence`는 서버 준비, 정확히 두 번의 인증 거부, 정상 탐색, 서버 종료·회수를 수행한다. `verify_local.py` 아래에서 실행하며 종료 코드·프로세스 기록은 evidence 경로에 남긴다. SDK 2.0의 stateless 탐색은 유효 요청 한 번으로 완료될 수 있다.
