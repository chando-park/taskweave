# Personal Codex Instructions

이 파일은 모든 저장소에 적용하는 개인 작업 원칙이다. 더 구체적인 저장소 `AGENTS.md`·`CLAUDE.md`와 함께 적용하며 프로젝트의 아키텍처·빌드·테스트 규칙을 임의로 덮어쓰지 않는다. `20_AI/Codex/Runtime`의 공통 reference와 스킬은 Codex·Claude가 공유하는 원본이다.

- 사용자 요청·대상과 적용되는 저장소/조직 지침을 확인한다. 질문·설명·진단은 수정 요청이 없으면 원본을 바꾸지 않는다.
- 기존 자료·범위 밖 사용자 변경을 보존한다. dirty worktree 자체는 중단 사유가 아니며 개인정보·비밀을 무단 복제하지 않는다.
- 새 요청·정정·범위 변경은 [공통 작업 흐름의 실행 연결](references/task-workflow.md#판단에서-실제-스킬로-이어가기)에서 경로를 선택하고 반환된 스킬을 실제로 적용한다. 코드·설정은 작은 수정도 변경 전후 코드·문구와 검증 방법을 먼저 설명한 뒤 승인받는다. 문서는 필요한 경우만 만들고 같은 안의 실행·재시도에는 승인을 반복하지 않는다. 글쓰기 기준도 공통 흐름에서 연결한다.
- 해당 작업의 스킬과 필요한 reference만 읽는다. 선택한 문서는 끝까지 읽고 동일 작업·revision의 맥락은 재사용한다. 시점이 지정된 규칙은 실제 편집/검토 직전에 적용한다.
- 기능 구현·동작 변경 전에는 [테스트 계획](references/verification-planning.md#구현-전-테스트-계획-설명-필수)을 반드시 먼저 설명한다. 기존 테스트의 확인 범위·빈틈, 수정·추가할 테스트와 이유, 실행 순서·통과 기준을 제시하고 변경안 승인 후 구현한다. 구현 결과를 보고할 때는 실제 테스트 통과·실패·건너뜀과 미실행 이유를 반드시 기록하고 사용자에게 알린다.
- 원문·요구사항과 결과를 대조하고 실행하지 않은 검증을 통과로 보고하지 않는다. 보고 때 [공통 검토와 보고](references/verification-evidence.md#공통-검토와-보고)를 적용하며 무관한 테스트·커버리지·보고서를 강제하지 않는다.
- 진행 중 안내와 결과는 [공통 설명 원칙](references/implementation-handoff.md#공통-설명-작성-원칙)에 따라 쉬운 한글로 설명한다. 확인한 사실·현재 문제·다음 행동·코드와 결과에 미치는 영향을 구분하고 미확인을 숨기지 않는다. 코드·명령·식별자·인용 계약은 원문을 유지하고 저장소의 명시 언어 규칙을 우선한다.
- 외부 게시·삭제·Git 게시·회사 종료·지식 게시 권한은 수행 요청에서 추정하지 않는다. 현재 작업 피드백은 [피드백 절차](references/acceptance-feedback-loop.md)에서 이어가며 회사 종료는 명시 완료 요청 뒤 `$cdpower:complete-work`만 수행한다.

## 필요한 시점의 연결

- 코드 변경/계획·Workplan 실행: [위험 분류](references/risk-routing.md)와 [실행 계약](references/execution-contract.md). 저위험 수정은 `$cdpower:code-change`, 복잡한 기능·버그 변경은 해당 plan 스킬을 사용한다. 회사의 필수 Workplan·프로젝트 지침을 따르되 Jira는 현재 작업에 적용되는 회사 정책상 필수일 때만 생성한다. 회사 저장소·Workplan 사용 자체를 티켓 생성 근거로 삼지 않는다.
- symbol·caller·implementation 조사/변경 전: [Serena Code Intelligence](references/serena-code-intelligence.md)의 semantic 사전 확인과 실제 symbol 도구를 사용한다. 정확한 문구·리소스·주석·문서·설정·단일 literal만 textual 예외이며 도구 부재를 광범위한 검색으로 조용히 대체하지 않는다.
- Swift 편집 직전: [Swift 코드 규칙](references/swift-code-conventions.md). UI 편집 직전: [디자인 시스템 계약](references/design-system-implementation-contract.md)의 필수 leaf·실제 component/token·외부 layout 선언을 읽는다. UI 원천/candidate·tier 검증은 해당 코드 스킬에서 유지한다.
- 요약·대본·보육일지 등 글쓰기 작성/수정: [글쓰기 작업](references/writing-work.md). 새로운 종류도 공통 흐름에서 이번 목적·원본·산출물·확인 방법을 정하며 자동 영구 규칙을 만들지 않는다.
- 실제 위임이 필요한 코드 작업: [Model Routing](references/model-routing.md). 작고 결정적인 작업은 부모가 직접 구현하고 라우터가 요구하는 경우만 반환된 실제 agent로 실행한다. 실행 가능한 GPT-6·6.x가 있으면 GPT-5·5.x를 제외하고 GPT-6 계열이 전혀 없을 때만 GPT-5를 사용한다. 인계·주석은 해당 시점에 [Implementation Handoff](references/implementation-handoff.md)·[Code Comment Contract](references/code-comment-contract.md)를 읽는다.
- CDPower 도구를 사용할 때: [플러그인 실행 연결](references/plugin-runtime.md). AI가 호스트 도구로 작업하고 MCP는 조회·현재 작업 찾기·안전한 기록 저장만 맡는다. 문서 형식 검사나 기술적 승인 기록을 구현 허가로 만들지 않는다.
