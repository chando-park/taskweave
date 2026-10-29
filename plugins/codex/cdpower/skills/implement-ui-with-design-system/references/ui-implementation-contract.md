# UI Implementation Contract

이 표는 별도 UI Workplan 양식이 아니라 `context_profile: ui|mixed`인 공통 feature bundle의 `Details/description.md`와 `Details/verification.md`에 추가하는 조건부 Context다.

화면 구현 승인 패킷에 다음 대응을 기록한다.

| 항목 | 확인 내용 |
| --- | --- |
| 대상 | 제품 저장소, 화면 진입점, Design System dependency·version·import |
| Figma | file, screen/view node, revision, layout·content·interaction |
| 제품 코드 | 동일·유사 화면, navigation·state 관용구, 호출 예시 |
| Design System | public token, component, Variant와 조합 관계 |
| UI API | content, state, Binding, 이벤트 전달과 제품 effect 경계 |
| 접근성 | label·value·traits, focus order, Dynamic Type |
| 누락 | 미구현 근거, 화면 한정·공통 후보 판정, ticket draft·dependency |
| 검증 | Preview, interaction/accessibility test, snapshot 또는 Figma 대조 |

실제 계획과 결과에는 [Design System Implementation Contract](../../../references/design-system-implementation-contract.md)의 미구현 판정과 자동화 제한도 함께 적용한다.
