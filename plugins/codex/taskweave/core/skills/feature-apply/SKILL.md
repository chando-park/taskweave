---
name: feature-apply
description: 현재 승인 feature Workplan의 코드와 직접 테스트를 구현하고 실제 변경·검증을 기록한다. 현재 구현 피드백은 기존 Workplan에서 이어가며 범위 변경은 재승인한다.
---

# 승인된 기능 구현

현재 대화의 feature Workplan과 [실행 계약](../../references/execution-contract.md)을 확인한다. Workplan이 없으면 과거 이력을 찾지 않고 $taskweave:feature-plan을 사용한다. implementing·verifying·verification_blocked·awaiting_completion 상태의 구현 피드백은 최초 승인·apply·Jira 확인을 반복하지 않고 $taskweave:apply-workplan-feedback으로 보낸다. 최초 구현은 현재 계획 버전이 제시되었고 사용자가 그 버전을 명시 승인했는지 확인한다. 승인이 없으면 계획 제시·승인 요청까지만 하고 응답을 끝낸다. 최초 구현 요청·기준 합의·이 Skill 호출을 승인으로 간주하지 않는다.

## 필요한 문서 선택

- UI 편집: $taskweave:implement-ui-with-design-system과 [디자인 시스템 계약](../../references/design-system-implementation-contract.md).
- Swift 편집 직전: [Swift 코드 규칙](../../references/swift-code-conventions.md)의 간격·체인·동시성·Preview를 적용하고 최종 diff에서도 확인한다.
- Swift 테스트 작성·수정: [Swift Testing 계약](../../references/swift-testing-contract.md).
- 비자명한 제약 주석 작성·수정: [주석 계약](../../references/code-comment-contract.md).
- 실제 위임: [모델 라우팅](../../references/model-routing.md)과 [구현 인계](../../references/implementation-handoff.md).
- 회사 티켓의 구현 시작: [티켓 절차](../../references/ticket-lifecycle.md).
- 결과 기록·검증 근거 판정: [검증 근거](../../references/verification-evidence.md)와 [Workplan 양식](../../references/workplan-layout.md).
- 모든 구현 시작·구현 중 문제 판단: [공통 인계의 설계 완료·문제 처리 기준](../../references/implementation-handoff.md#승인-전-설계-완료-판단). 승인한 설계를 적용하며 빈 설계는 구현하면서 채우지 않는다. 같은 승인으로 고칠 오류·설계 변경·원복은 이 기준으로 구분한다.

## 코드 수정 시작

1. 실제 대화에서 제시한 계획 버전·범위에 대한 사용자 승인을 확인하고 그 내용을 현재 기록에 한 번 남긴다. 이미 기록했으면 반복하지 않는다. 실제 승인 없이 출처를 만들지 않으며 중요한 범위 변경이 함께 왔으면 해당 추가 계획의 승인을 받는다.
2. AI가 호스트 도구로 승인 범위를 수정한다. 범위 밖 dirty 변경을 보존하고 대상 변경·실제 충돌만 해당 편집을 중단한다. MCP 또는 CLI의 approve·apply·문서 검사 성공을 시작 조건으로 요구하지 않는다.
3. 연결된 회사 티켓이 있고 정책이 시작 동기화를 요구할 때만 한 번 동기화한다. 연결 key가 없으면 구현 시작을 이유로 티켓을 새로 만들지 않는다. 생성은 현재 작업의 티켓이 회사 정책상 필수인 경우에만 티켓 절차를 따른다. Jira를 완료하지 않는다.
4. 원인·파일·심볼·수정 방향·직접 검증이 확정된 단일 저장소 작업은 부모가 바로 수정한다. 외부 계약·다중 저장소·새 아키텍처·반복 실패 등 위임 조건일 때만 model-route가 선택한 실제 담당에게 넘긴다.

## 구현·검증·설명

검증에서 승인 범위 안 오류가 나오면 같은 구현에서 수정·재검증한다. 새 설계가 필요하면 제품 편집만 멈추고 [문제 처리 기준](../../references/implementation-handoff.md#구현-중-문제가-발견됐을-때)에 따라 실패 근거·원본·대안 코드·검증안을 같은 Workplan에 준비한다. 외부 장애이면 부족한 입력과 재개할 지점을 설명한다. “계획 코드 적용”이나 실패 결과 보고로 문제 해결을 대신하지 않는다.

- 구현 결과 보고 직전에 $taskweave:explain-code를 적용한다. 실제 변경 전체의 코드·이유·호출 흐름과 테스트 목록·결과·커버리지를 설명하고 복잡한 결과는 실행·데이터·조건 흐름을 먼저 그림으로 보여 주고 단계별 코드·이유·테스트를 연결한다. 사용자 최종 완료 요청까지 미루지 않는다.
- symbol·caller·implementation 변경 직전 [Serena 절차](../../references/serena-code-intelligence.md)로 실제 코드 경계를 확인한다. 정확한 text/resource/literal 변경만 textual 예외다.
- 승인한 state/action/branch·API·dependency·caller·assembly와 저장소 아키텍처·생성·현지화 규칙을 적용한다. 승인 밖 Public/외부 계약·저장 형식·저장소·주요 동작 변경은 멈추고 재승인한다.
- 계획한 직접 테스트부터 실행하고 위험에 비례해 빌드·정적 검사를 더한다. 원천의 수치·경계 기대값은 구현 상수와 독립된 근거를 사용한다. 마지막 diff의 주석·코드·검증이 일치하는지 확인한다.
- 승인된 검증 계획을 담당에게 전달한다. 테스트가 실행 불가능해졌으면 사유와 가장 좁은 대안을 기록하며 제품 완료 조건이 바뀔 때만 재승인한다.
- 직접 경로는 부모가 승인 범위와 실제 diff를 검토한다. 위임의 실행·실패·인계는 모델 라우팅을 따르고 같은 입력의 테스트를 관성적으로 반복하지 않는다.
- 결과 기록 전에 [테스트·커버리지 기록](../../references/verification-evidence.md#테스트커버리지-기록)을 읽고 테스트별 결과·집계·커버리지를 현재 Workplan 문서의 검증 영역에 통합한다. 같은 테스트·실행 대상·설정은 최신 결과로 갱신하고 Completion에는 요약과 그 위치를 연결한다. 기록 형식이나 미측정만으로 새 문서 검사·완료 차단 조건을 추가하지 않는다.

호스트 파일 도구 또는 `record_save`로 실제 diff·계획 편차·명령·결과·미실행 범위를 Completion.md에 기록한다. 실제 직접 검증이 통과하면 awaiting_completion, 미실행은 verifying, 외부 차단은 verification_blocked로 구분한다. 실제 구현·원천 불일치는 수정하며 문서 형식 검사를 제품 성공 기준으로 쓰지 않는다. 제목·필드·설명 부족은 경고하고 끝에 한 번 보완하며 같은 승인·테스트를 반복하지 않는다. 저장 실패·충돌은 [플러그인 실행 연결](../../references/plugin-runtime.md)에 따라 해당 저장만 처리한다.

구현 결과를 전달하기 전에 [구현 결과의 빠짐없는 설명](../../references/verification-evidence.md#구현-결과의-빠짐없는-설명)을 읽는다. 실제 추가·변경·삭제한 타입·프로퍼티·함수·분기와 호출 흐름을 빠짐없이 설명하고, 실제 코드·변경 이유·테스트 목록과 결과 집계·커버리지 또는 미측정 이유를 함께 보여 준다. 긴 상세는 같은 Workplan에 연결하되 앞선 계획·합계·결과 링크 하나로 대신하지 않는다. $taskweave:complete-work의 사용자 완료 요청 전에는 지식 평가·게시·Jira/Workplan 종료를 수행하지 않는다. 기존 mapping·revision·Details·gate 이력은 보존하되 과거 문서 gate를 새 CDPower 편집 선행 조건으로 승계하지 않는다.
