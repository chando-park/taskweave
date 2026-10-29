---
name: plan-ui-with-design-system
description: feature-plan의 같은 메모에 Figma 화면·상태, 디자인 시스템 사용과 필요한 UI 검증 범위를 더한다. 새 공통 컴포넌트 계획은 별도 스킬로 보낸다.
---

# 디자인 시스템 기반 UI 계획

/cdpower:feature-plan의 같은 approval-memo-v1을 사용하며 별도 UI Workplan·승인 절차를 만들지 않는다.

- 컴포넌트·토큰·책임 경계 선택: [디자인 시스템 계약](../../references/design-system-implementation-contract.md)을 읽는다. 대상 View·state/action·상호작용·navigation·Preview·테스트와 실제 component/token 선언·consumer를 확인한다.
- 검증 필요 여부·단계·원천·렌더 경계 결정: [UI 검증](../../references/ui-verification.md)을 읽고 Workplan에 ui_verification_tier와 근거를 둔다. 실행 증거 작성은 구현 단계에 남긴다.
- 공통 component의 새 public 계약: /cdpower:plan-design-system-component로 분리한다. 제품 코드에 임시 공통 API를 숨겨 만들지 않으며 후속 작업은 사용자 요청 범위에서 생성한다.

사용자가 제공하거나 Project Agent가 연결한 정확한 Figma file·screen/view node·revision·state를 확인한다. screenshot·유사 화면을 공식 원천으로 대체하거나 코드 값을 원천 기대값으로 사용하지 않는다. 원천의 기본값·허용 예시·실제 instance override·geometry·접근성·제품 동작을 구분하고 사용자 문구의 현지화 원천·accessor를 확인한다.

none은 시각 계약이 그대로이고 승인된 값·상태 직접 검증이 적합한 경우다. regression은 원천 출처가 확인된 동일 상태의 기존 Golden이 있을 때만 사용한다. 새 시각 상태·픽셀 변경 또는 Golden 출처 부재는 정확한 원천과 앱 렌더를 대조하는 conformance/full로 계획한다. 필요한 원천을 찾을 수 없을 때만 URL·node·결정을 질문한다.

conformance/full은 source → candidate → 독립 comparison → pre-golden authorization → Golden 승격 순서를 유지한다. build·Canvas 성공은 원천 적합성을 대신하지 않는다. 실제 CLI는 --ui-tier, 메타데이터는 ui_verification_tier를 사용한다.

/cdpower:feature-plan이 같은 메모의 실제 코드·검토 방법을 설명하고 필요한 사용자 승인을 받는다. 별도 prepare·문서 형식 검사를 승인안 제시 조건으로 삼지 않는다. 지식 문서·UI 결과 보고서·중복 승인 기록을 미리 만들지 않는다.
