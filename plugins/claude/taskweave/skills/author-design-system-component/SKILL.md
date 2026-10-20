---
name: author-design-system-component
description: 승인된 디자인 시스템 컴포넌트 Workplan의 API·token·Variant를 구현하고 공식 원천과 렌더를 검증한다. 제품 화면·상위 작업은 자동 변경하지 않는다.
---

# 승인된 공통 디자인 컴포넌트 구현

현재 대화의 component Workplan과 [디자인 시스템 계약](../../references/design-system-implementation-contract.md)을 읽는다. 없으면 과거 문서를 찾지 않고 /taskweave:plan-design-system-component를 사용한다. 승인 source·변경 Variant/property·public API/token/event·target repository·최소 검증이 모두 있어야 한다.

## 필요한 문서 선택

- symbol·consumer 조사·변경: [Serena 절차](../../references/serena-code-intelligence.md).
- Swift 테스트 작성·수정: [Swift Testing 계약](../../references/swift-testing-contract.md).
- 회사 티켓 시작: [티켓 절차](../../references/ticket-lifecycle.md).
- 실제 위임 조건: [모델 라우팅](../../references/model-routing.md)과 [구현 인계](../../references/implementation-handoff.md).
- 원천·candidate·Golden 검증: [UI 검증](../../references/ui-verification.md).
- 결과·권한·설명: [Workplan 양식](../../references/workplan-layout.md)과 [실행 계약](../../references/execution-contract.md).

## 구현·검증

1. 제시한 계획에 대한 실제 사용자 승인을 확인하고 한 번 기록한 뒤 호스트 도구로 수정한다. 기록 형식 검사·기술적 승인 처리를 구현 시작 허가로 삼지 않는다. 현재 구현의 피드백은 /taskweave:apply-workplan-feedback으로 이어간다.
2. 연결 회사 티켓은 정책상 시작 상태로 한 번 동기화한다. 직접 경로이면 부모가 수행하고 새 public 계약·불확실성 등 위임 조건이면 source·선언·consumer·generation pipeline·승인 코드·테스트를 실제 담당에게 전달한다.
3. Design System repository의 승인 범위만 수정한다. public API·Variant/property·semantic token·asset/codegen·event·accessibility를 적용하고 생성 결과물을 직접 편집하거나 Figma/public token에 없는 값·상태를 발명하지 않는다.
4. 변경 Variant의 Preview를 유지하고 승인한 compile·직접 test·대표/경계 Snapshot과 공식 source/candidate 대조를 실행한다. Canvas·모니터·다른 worktree 이미지로 대신하지 않는다.
5. source 불일치는 승인 범위에서 수정·재렌더한다. 새 token/API/Variant/state·제품 repository·공식 source 변경은 재승인한다. conformance/full은 source → candidate → machine comparison → pre-golden authorization → Golden 승격 → Snapshot 순서를 지키며 현재 렌더를 정답으로 먼저 쓰지 않는다.

같은 Workplan에 실제 component before/after·caller/codegen·render/test·미실행 범위를 기록한다. 형식 보완은 끝에 묶고 자동 문서 검사를 보고 허가로 삼지 않는다. 실제 필요한 검토가 통과했을 때만 awaiting_completion이며 미실행·외부 차단을 구분한다. UI 비교 실패를 다른 검증 성공으로 덮거나 상위 제품 화면·작업을 자동 재개하지 않는다. 실제 코드·이유·흐름을 설명하고 최종 종료·지식 평가는 사용자 명시 완료 요청 뒤 /taskweave:complete-work에 맡긴다. 기존 기록·증거는 보존한다.
