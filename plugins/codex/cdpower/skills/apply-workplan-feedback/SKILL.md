---
name: apply-workplan-feedback
description: 현재 Workplan의 수정 피드백을 같은 범위·재승인·독립 작업으로 나누고 현재 구현에서 이어간다. Workplan 없는 코드·글쓰기는 현재 대화에서 이어간다.
---

# 현재 작업 피드백 처리

[공통 작업 흐름의 실행 연결](../../references/task-workflow.md#판단에서-실제-스킬로-이어가기)에서 현재 Workplan·관련 피드백으로 확인한 결과를 이어받는다. 같은 프로젝트 등록·최초 조사를 반복하지 않고 바뀐 사실에만 분류를 갱신한다.

먼저 현재 대화의 결과물·기준과 Workplan 유무를 확인하고 [피드백 절차](../../references/acceptance-feedback-loop.md)를 읽는다. 원인 질문·완료 요청에 섞인 문제 제보도 이 스킬의 입력이다. 원인이 불확실하면 같은 문서의 [조사→수정안 연결](../../references/acceptance-feedback-loop.md#원인-조사에서-수정안까지-이어가기)을 실제로 수행한 뒤 아래 경로를 선택한다. Workplan 없는 코드는 $cdpower:code-change, 보육일지·요약·대본 등은 [글쓰기 작업](../../references/writing-work.md)의 자료·규칙·검토 기준으로 현재 수정본에서 이어간다. 글쓰기에 코드 diff·Git·MCP 연결을 요구하거나 피드백 때문에 사후 Workplan을 만들지 않는다. 코드 Workplan일 때만 현재 기록·관련 diff를 읽고 아래 범위를 적용한다. 과거 작업 전역 검색으로 대상을 추정하지 않는다.

## 경로 선택

- 같은 범위 correction: 이미 제시·승인한 안 안의 구현·검증 실패 수정은 같은 승인으로 직접 영향만 처리한다. 새 사용자 피드백으로 추가 코드·검증안이 생기면 그 안만 먼저 보여 주고 승인받는다. 최초 조사·기술적 stamp·시작 처리·Jira 상태 확인은 반복하지 않는다.
- 의미 범위 변경: 현재 구현을 보존하고 같은 Workplan에 추가 현재/제안 코드·검증을 보여 준다. 실제 사용자 재승인 내용을 한 번 기록하고 그 범위만 이어간다. 최초 코드 상태로 복구하지 않는다.
- 독립 결함·기능: 새 계획 경로를 사용한다. Public/외부 계약·저장 형식·repository·주요 동작·승인 UI source 변경은 correction으로 숨기지 않는다.

## 필요한 문서와 기능

- 추가·변경 계획의 승인 요청 직전과 수정 결과 보고 직전: $cdpower:explain-code를 적용한다. 승인안은 [기존 설계 완료 판단](../../references/implementation-handoff.md#승인-전-설계-완료-판단)의 현재/제안 코드·이유·검증 방법을 사용자에게 실제로 설명한 뒤 승인을 요청한다. 결과는 실제 diff·실행 근거로 설명한다. 같은 승인 안의 오류 수정에 새 승인을 요구하지 않으며 동일한 설명은 재사용한다.
- symbol 경계 조사·변경: [Serena 절차](../../references/serena-code-intelligence.md). 정확한 같은 범위의 text/resource/literal correction은 textual 예외다.
- Swift 편집 직전: [Swift 코드 규칙](../../references/swift-code-conventions.md). 최종 diff에서 간격·체인·동시성·Preview를 확인하며 테스트 작성/수정 시 연결된 Swift Testing 계약도 읽는다.
- UI feedback: [디자인 시스템 계약](../../references/design-system-implementation-contract.md)과 [UI 검증](../../references/ui-verification.md). 같은 source·render root·visible region인지 실제 영향으로 판단하며 관계가 넓어지면 필요한 rule leaf·선언과 공통 render root의 원천을 확인한다. 문서 manifest·gate 영수증을 새 CDPower 편집 허가로 요구하지 않고 실제 독립 원천·candidate 비교는 유지한다.
- 결과 기록: [Workplan 양식](../../references/workplan-layout.md)과 [실행 계약의 보고](../../references/execution-contract.md#사용자-상태-보고).

코드 피드백 수정 결과도 [구현 결과의 빠짐없는 설명](../../references/verification-evidence.md#구현-결과의-빠짐없는-설명)으로 이번에 추가·변경·삭제한 타입·함수·분기와 호출 흐름, 실제 코드·테스트 목록·결과·커버리지 또는 미측정 이유를 함께 보고한다. 앞선 결과와 같은 부분은 위치를 재사용하되 새 변경을 '추가 수정'이라는 말로 생략하지 않는다.

같은 source·state의 누락된 부모 화면 근거 보충은 evidence repair이고 다른 디자인·state·revision·제품 동작은 재승인이다. 여러 같은 범위 피드백은 모아 직접 영향 검증을 마지막에 한 번 실행한다. 제목·필드·설명 양식 부족은 경고하고 마지막에 보완하며 실제 원문 부족·제품 검증 실패와 구분한다.

AI가 호스트 도구로 수정·직접 검증하고 필요한 기록은 호스트 파일 도구 또는 `record_save`로 갱신한다. 실제 검증이 통과한 Workplan은 awaiting_completion이며 미실행·실패를 성공으로 바꾸지 않는다. 이전 MCP/CLI의 correction-start·feedback-apply·result 검사를 선행 조건으로 강제하지 않는다. 저장 실패·충돌은 [플러그인 실행 연결](../../references/plugin-runtime.md)에 따라 해당 저장만 처리한다. Workplan/Jira 종료·지식 평가·게시·commit·push를 하지 않으며 피드백과 완료 표현이 함께 오면 수정·검증 뒤 새 완료 요청을 기다린다. 기존 feedback/Details·승인 이력은 보존하고 자동 migration하지 않는다.
