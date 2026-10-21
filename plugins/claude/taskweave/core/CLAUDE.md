# Personal Claude Code Instructions

이 파일은 Claude Code의 portable global contract다. 더 구체적인 저장소 `CLAUDE.md`·`AGENTS.md`와 함께 적용하며 프로젝트 아키텍처·빌드·테스트 규칙을 임의로 덮어쓰지 않는다. 아래 `Codex/Runtime` 경로의 reference·스킬은 두 호스트가 공유하는 원본이다.

- 사용자 요청·대상과 적용되는 저장소/조직 지침을 확인한다. 질문·설명·진단은 수정 요청이 없으면 원본을 바꾸지 않는다.
- 기존 자료·범위 밖 사용자 변경을 보존한다. dirty worktree 자체는 중단 사유가 아니며 개인정보·비밀을 무단 복제하지 않는다.
- 새 작업을 선택할 때 [공통 작업 흐름](./references/task-workflow.md)을 읽는다. 코드·설정은 작은 수정도 변경 전후 코드·문구와 검증 방법을 먼저 보여 주고 승인 후 편집한다. 문서는 필요한 경우에만 만들고, 같은 승인안의 실행·재시도에는 승인을 반복하지 않는다. 글쓰기 등 작업별 자료·규칙·검토 방법은 공통 흐름에서 연결한다.
- 필요한 스킬/reference만 선택해 끝까지 읽고 동일 작업·revision의 맥락은 재사용한다. 시점이 지정된 규칙은 실제 편집/검토 직전에 적용한다.
- 원문·요구사항과 결과를 대조하고 실행하지 않은 검증을 통과로 보고하지 않는다. 보고 때 [공통 검토와 보고](./references/verification-evidence.md#공통-검토와-보고)를 적용하며 무관한 테스트·커버리지·보고서를 강제하지 않는다.
- 결과와 실제 확인·미확인 범위는 쉬운 한글로 설명한다. Workplan·승인안·Completion도 한글이 기본이며 코드·명령·식별자·인용 계약과 저장소의 명시 언어 규칙은 유지한다.
- 외부 게시·삭제·Git 게시·회사 종료·지식 게시 권한은 수행 요청에서 추정하지 않는다. 현재 피드백은 [피드백 절차](./references/acceptance-feedback-loop.md)에서 이어가고 회사 종료는 명시 완료 요청 뒤 `/taskweave:complete-work`만 수행한다.

## 필요한 시점의 공통 연결

- 코드 변경/계획·Workplan 실행: [위험 분류](./references/risk-routing.md)와 [실행 계약](./references/execution-contract.md). 저위험은 `code-change`, 복잡한 기능·버그 변경은 해당 plan 스킬을 사용한다. 회사의 필수 Workplan·프로젝트 지침을 따르되 Jira는 현재 작업에 적용되는 회사 정책상 필수일 때만 생성한다. 회사 저장소·Workplan 사용 자체를 티켓 생성 근거로 삼지 않는다.
- symbol·caller·implementation 조사/변경 전: [Serena Code Intelligence](./references/serena-code-intelligence.md)의 semantic 사전 확인과 실제 symbol 도구를 사용한다. 정확한 문구·리소스·주석·문서·설정·단일 literal만 textual 예외이며 도구 부재를 광범위한 검색으로 조용히 대체하지 않는다.
- Swift 편집 직전: [Swift 코드 규칙](./references/swift-code-conventions.md). UI 편집 직전: [디자인 시스템 계약](./references/design-system-implementation-contract.md)의 필수 leaf·실제 component/token·외부 layout 선언을 읽는다. UI 원천/candidate·tier 검증은 해당 코드 스킬에서 유지한다.
- 요약·대본·보육일지 등 글쓰기 작성/수정: [글쓰기 작업](./references/writing-work.md). 새로운 종류도 이번 목적·원본·산출물·확인 방법부터 정하며 자동 영구 규칙을 만들지 않는다.
- 주석 작성·코드 인계 시: [Code Comment Contract](./references/code-comment-contract.md)·[Implementation Handoff](./references/implementation-handoff.md).

## Claude 도구와 역할

- Taskweave 도구를 사용할 때 [플러그인 실행 연결](./references/plugin-runtime.md)을 읽는다. AI가 호스트 도구로 작업하고 MCP는 조회·현재 작업 찾기·안전한 기록 저장만 맡는다. 기존 CLI 승인·시작·검증 orchestration으로 대체 강제하지 않으며 Codex 설치를 요구하지 않는다.
- 코드 작업의 위험·불확실성에 따라 `general`, 좁고 결정적인 `routine`, 기존 token의 좁은 UI인 `ui-narrow`, 상충·넓은 영향·고위험 계약의 `high-risk`를 선택한다. 실제 위임이 필요하면 선택 역할을 실행한다. 사용할 수 없으면 그 사실을 기록하고 실행하지 않은 역할이나 Codex 모델을 사용했다고 주장하지 않는다.
- 부모는 승인·Workplan/티켓 수명주기·최종 검토·지식 완료·Git 전달을 소유한다. 담당자는 실제 변경 파일·diff·검증·범위 편차를 반환한다.
