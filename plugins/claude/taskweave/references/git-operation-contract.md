# Git Operation Contract

커밋·푸시·PR/MR 전에 다음을 확인한다.

- 실제 Git root, `origin`, 현재 branch
- 사용자가 지정한 저장소·remote·branch와의 일치
- 스테이징할 파일과 제외할 사용자 변경
- 비밀, 인증서, 생성물, 임시 파일 포함 여부
- 요청 모드: `commit`, `commit-push`, `commit-push-mr`

대상이 불일치하거나 둘 이상이면 중단한다. 관련 파일만 명시적으로 stage하고 `git diff --cached --check`와 staged diff를 확인한다. `--no-verify`, force push, CI skip은 기본 사용하지 않는다. PR/MR 생성과 병합은 각각 명시적으로 요청된 경우에만 수행한다.

PR/MR 본문은 구조화 입력에서 파일로 생성하고 lint한 뒤 게시한다. Markdown을 shell command 문자열로 조립하지 않으며 백틱·`$()`·실제 줄바꿈을 보존한다. reviewer 선정과 fallback template은 provider Skill의 고유 계약으로 유지하며 공통화 과정에서 삭제하지 않는다.
