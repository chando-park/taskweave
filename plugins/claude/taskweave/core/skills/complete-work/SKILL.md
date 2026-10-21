---
name: complete-work
description: 사용자가 완료를 요청한 현재 코드·문서 작업의 결과와 실제 검토를 확인한다. 일반 대화 수용과 Workplan 종료를 구분하고 회사 Workplan만 지식·티켓 adapter를 실행한다. 구현·Git 게시는 하지 않는다.
---

# 현재 작업 완료

현재 작업과 사용자의 완료 요청을 확인하고 [공통 작업 흐름](../../references/task-workflow.md)에 따라 대화 결과 수용과 Workplan 종료를 구분한다. 보육일지·요약·대본 등 일반 글쓰기는 결과 전달로 끝낼 수 있고 이 스킬의 별도 호출·명시 완료를 매번 요구하지 않는다. 피드백과 완료가 함께 오면 현재 코드/글쓰기/Workplan의 피드백 경로에서 수정·검토를 먼저 처리한다. Workplan은 새 완료 요청 전에는 종료하지 않는다. 제품 cleanup·추가 구현·commit·push·PR/MR·미검증 수용 권한을 추정하지 않는다.

## 경로별 문서 선택

- Workplan 없는 요약·대본/일반 문서: [공통 검토와 보고](../../references/verification-evidence.md#공통-검토와-보고)와 필요한 [글쓰기 작업](../../references/writing-work.md)만 읽는다. 원문·의도·분량 등 실제 기준과 수정본을 확인하고 대화로 결과·한계를 설명한다. Git/resolver·Serena·앱 테스트·커버리지·회사 adapter·자동 지식 평가를 요구하지 않는다.
- Workplan 없는 코드: [실행 계약](../../references/execution-contract.md)의 대화 종료 기준을 적용한다. 대화의 승인안·실제 diff·마지막 편집 이후 직접 검증을 대조하고 필요한 기존 문서가 있을 때만 결과를 확인한다. 문서가 없는 작업에 회사 adapter·사후 Workplan·Completion·hash 파일을 만들지 않는다.
- 개인 Workplan: [Workplan 양식](../../references/workplan-layout.md)과 [검증 근거](../../references/verification-evidence.md)로 현재 결과·승인·검증을 확인한다.
- 회사 Workplan: 위 확인 뒤 [지식 수명주기](../../references/knowledge-lifecycle.md), [회사 adapter](../../references/company-workplan-adapter.md), [티켓 절차](../../references/ticket-lifecycle.md)를 읽고 resolver가 반환한 정확한 현재 작업의 정책·adapter만 실행한다.
- 누락된 코드 설명·자료 또는 인계 문제가 있을 때: [구현 인계](../../references/implementation-handoff.md).

## 현재 결과 확인

먼저 위 대화 문서 분기면 원문·산출물·검토 결과만 확인해 보고한다. 다음 resolver·diff·테스트 절차는 코드/Workplan 분기에만 적용한다. 그 분기에서 resolve-task-context와 필요 시 resolve-workplan-policy로 repository·remote·branch·정책을 확인하고 실제 tracked/untracked diff·HEAD·코드 설명과 유효한 검증을 대조한다. 실패·미실행·오래된 검증을 통과로 바꾸지 않으며 필요한 구현 설명·UI·산출물 확인만 수행한다. 무관한 사용자 변경을 보존하고 과거 Workplan·유사 티켓을 다시 찾지 않는다. 코드가 아닌 의무 회사 기록은 해당 문서 정책을 따르며 Git hash를 꾸미지 않는다.

approval-memo-v1은 기존 Completion.md의 실제 diff·검증 identity가 같으면 보존하고 변경된 사실만 호스트 파일 도구 또는 `record_save`로 기록한다. 사용자 완료 요청 내용·시각을 한 번 남긴다. 결과 확인과 사용자 최종 완료는 다른 단계다. 기록 제목·필드·설명 부족은 경고하고 마지막에 보완하며 이전 MCP/CLI의 result·completion validate 성공을 새 종료 허가로 만들지 않는다. 실제 검증 실패·필수 원문 부족·무권한·저장 충돌은 형식 문제와 구분한다.

코드 테스트가 해당하는 완료 보고 전에는 [테스트·커버리지 기록](../../references/verification-evidence.md#테스트커버리지-기록)으로 현재 결과를 확인한다. 실제 테스트별 결과·집계·커버리지 또는 미측정 이유를 응답에 설명하고 기존 작업 문서가 있을 때만 해당 검증 영역을 갱신한다. 별도 보고서·중복 표·보고용 재실행·형식 검사를 추가하지 않는다. 비코드에는 실제 원문/표현/형식 검토와 한계를 보고하고 테스트·커버리지 행을 강제하지 않는다.

## 회사 지식·티켓 종료

이 절은 명시 완료 권한이 있고 resolver가 회사 Workplan으로 확인한 현재 작업만 사용한다. 개인 결과물·일반 문서·대화 계획에는 자동 적용하지 않는다. 영구 규칙/스킬 반영은 별도 사용자 동의가 필요하다.

1. 명시 완료 권한 뒤 현재 diff·코드 설명·검증과 작업 중 읽은 관련 Standard·Current·Decision만으로 candidate 또는 no_change를 평가한다.
2. 후보는 검증된 제품 동작·정책·안정 계약·책임 경계·반복 규칙·권한 있는 결정이다. 코드 덤프·파일 목록·건수·로그는 제외한다. 목적지·주장·상충만 남기며 새 knowledge.md를 만들지 않는다. 상충·목적지 확대는 질문한다.
3. 회사 작업공간 안의 adapter와 explicit_completion_required를 확인하고 post_verify_hook_script <Workplan> --completion-result <Completion.md> --format json을 실행한다.
4. await_user_completion이면 멈춘다. promote_completion_knowledge이면 지정 Skill로 게시하고 strict lint를 실행한다. complete_without_knowledge_promotion이면 게시·게시 lint만 생략한다.
5. 게시 locator·성공/실패를 publication_attempts에 남긴다. 실패는 게시부터 재개하며 제품 코드·검증 입력이 같으면 테스트를 반복하지 않는다.
6. 정책상 완료 댓글을 작성·재조회하고 실제 Jira Done을 확인한 뒤 Workplan을 completed로 전환한다. 게시·Jira 실패는 awaiting_completion과 결과·시도 이력을 보존한다.

## 개인·레거시 종료와 보고

개인 Workplan은 사용자 명시 완료 요청 뒤 현재 결과·실제 승인 범위·유효한 직접 검증을 확인하고 행정 상태 completed와 completed_at을 기록한다. 회사 adapter나 문서 completion validator를 새 허가 조건으로 사용하지 않는다. 기존 schema·승인 hash·Details·회사 승격 이력은 보존하고 새 양식으로 바꾸지 않는다. 문서 형식 완화는 실제 제품 실패·필요한 회사 권한을 우회하는 근거가 아니다. 저장 안전·미저장 보고는 [플러그인 실행 연결](../../references/plugin-runtime.md)을 따른다.

[사용자 상태 보고](../../references/execution-contract.md#사용자-상태-보고)에 따라 실제 변경 전후 핵심 코드·이유·흐름·검증·미실행 범위·Git 상태를 직접 설명한다. 회사 종료는 지식 평가·게시 locator와 Workplan/Jira 결과도 포함한다. 앞선 설명·링크로 실제 코드 설명을 대신하지 않는다. 수행하지 않은 commit·push·게시를 완료로 보고하지 않는다.
