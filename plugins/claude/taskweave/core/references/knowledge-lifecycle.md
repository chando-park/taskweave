# Knowledge Lifecycle Contract

회사 작업의 지식 평가는 계획 승인 항목이 아니라 검증된 구현을 종료할 때 수행하는 완료 결과다. 새 `workplan_schema: approval-memo-v1` Workplan은 계획·승인·구현·검증 동안 지식 후보나 `Details/knowledge.md`를 만들지 않는다. 사용자의 명시적 `완료 처리`가 있을 때만 실제 결과에서 지식을 평가하고, 회사 adapter가 허용한 범위에서 게시한다.

## 새 approval memo 계약

- 정식 기록이 필요한 새 작업만 짧은 approval memo Workplan을 갖는다. 문서 없는 code-change·일반 글쓰기에 사후 Workplan을 만들지 않는다. 현재 작업의 수정은 같은 기록에서 이어간다.
- 실제 사용자 승인과 범위를 보존한다. 기존 hash 방식은 이유·범위·최소 검증을 결속하며 구현 결과·지식 평가는 그 hash를 바꾸지 않는다. 새 대화 승인에 없는 hash를 만들거나 기존 hash를 삭제해 우회하지 않는다.
- `draft → awaiting_approval → approved → implementing → awaiting_completion` 동안 `knowledge_sync_status: not_evaluated`와 지식 평가 부재가 정상이다.
- 구현 결과와 코드 설명·검증은 bundle의 별도 `Completion.md`에 기록할 수 있다. 사용자 완료 요청 전 결과의 지식 상태는 `not_evaluated`이며 게시를 시작하지 않는다.
- 일반 결과는 읽기 쉬운 `Completion.md`에 기록한다. 회사 완료 도구가 `approval-memo-result-v1`을 읽는 경우에만 회사 adapter가 같은 문서에 최소 입력을 연결한다. 별도 결과 복사본·수동 양식 채우기·새 승인 검사를 요구하지 않는다. 기존 구조화 결과와 승인 이력은 보존한다.

## 완료 시 평가 입력

`complete-work`는 사용자의 현재 완료 요청을 기록한 뒤 다음 근거만 사용한다.

1. 승인 범위 안의 실제 diff와 변경 파일
2. `Completion.md`의 코드 설명과 현재 검증 결과
3. 이 작업을 계획·구현하면서 이미 읽은 관련 Product Memory Standard·Current·Decision

완료를 위해 과거 Workplan이나 유사 티켓 전체를 다시 검색하지 않는다. 근거가 빠졌거나 마지막 검증 뒤 제품 코드·테스트가 바뀌었으면 지식 평가보다 공통 완료 검증을 먼저 복구한다.

## 평가 결과

완료 요청 뒤 정확히 하나를 기록한다.

- `candidate`: 다음 작업에서도 재사용할 검증된 제품 정책·동작, architecture·API·데이터·디바이스 계약과 책임 경계, 반복 적용할 구현·검증 규칙 또는 권한 있는 결정이 새로 생기거나 달라졌다. 목적지와 간결한 주장, 직접 근거를 함께 기록한다.
- `no_change`: 장기 재사용할 새 지식이 없다. 별도 `knowledge.md`를 만들지 않고 `Completion.md`의 짧은 완료 요약에 이유와 실제 diff·코드 설명·검증 근거를 남긴다.

파일별 코드 덤프, 심볼 목록, 테스트 건수, 명령 로그, 티켓 진행 기록과 일회성 우회는 Product Memory 후보가 아니다. 이 내용은 완료 결과와 Git·검증 artifact에만 남긴다.

목적지나 적용 제품·프로젝트를 실제 승인 범위보다 넓히거나 기존 Product Memory와 상충하면 추측해 합치지 않는다. `conflicts`에 남기고 사용자 선택 전 게시와 완료를 중단한다.

## 게시와 재시도

사용자가 명시적으로 완료를 요청했고 candidate가 있으면 회사 adapter가 다음을 수행한다.

1. 검증된 Event와 해당 Current·Interface·Standard·Decision·Problem·Runbook만 같은 변경 묶음으로 반영
2. Product Memory strict lint
3. 성공한 게시 locator를 `Completion.md`의 `publication_attempts`에 추가
4. Jira 완료 댓글·상태를 재확인한 뒤 Workplan을 `completed`로 동기화

`no_change`는 Product Memory 게시와 게시 lint만 생략한다. 사용자 완료 요청, 공통 완료 게이트, Jira 완료 확인과 Workplan 완료 동기화는 그대로 필요하다.

게시나 lint가 실패하면 검증된 코드 결과를 지우거나 코드·테스트를 다시 실행하지 않는다. Workplan은 완료 대기 상태와 기존 `publication_attempts`를 보존하며 다음 시도는 실패한 게시 단계부터 재개한다. 게시 이후 코드가 실제로 바뀐 경우에만 완료 결과와 검증을 다시 만든다.

`completed`는 검증 완료, 실제 candidate/no_change 평가, 명시적 완료 요청 기록, 상충 없음과 회사별 Jira 조건이 모두 확인된 때만 허용한다.

## 레거시 호환성

기존 `approval_revision_schema: scope-v3`, `Details/knowledge.md`, `Details/knowledge-candidate.md`, `knowledge_sync_pending`, `team_wiki_candidate` 계약은 기존 approval hash와 계획을 그대로 보존한다. 레거시 Workplan을 `approval-memo-v1`으로 일괄 변환하거나 승인 문서를 수정하지 않는다. 완료 시 별도 결과를 보강할 수 있지만 기존 지식 역할과 별도 승인 조건은 해당 Workplan의 원래 계약대로 검사한다.
