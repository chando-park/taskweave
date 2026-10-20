# Design System Implementation Contract

제품 UI가 기존 Design System을 소비할 때의 책임 경계만 정한다. 공통 컴포넌트의 canonical Figma source, `COMPONENT_SET`/`COMPONENT` Variant·property 조사와 public API 계획은 [/taskweave:plan-design-system-component](../skills/plan-design-system-component/SKILL.md)가 소유한다. 이 문서는 그 상세를 복제하지 않는다.

## 근거와 소유권

- **모든 UI 수정의 편집 직전:** direct fix, 계획 후 apply, 승인 후 feedback 모두 저장소 Agent와 Context Pack이 지정한 필수 UI rule leaf를 실제로 읽는다. index·catalog·링크를 찾은 것만으로 읽음을 대신하지 않으며, 속도를 위해 필수 leaf를 생략하지 않는다. 이미 유효하게 읽은 Context는 재수집하지 않고, 이번 View·state에 관련된 leaf만 확인한다.
- 그 leaf가 가리키는 실제 Design System의 component/token declaration과 layout 사용 규칙을 확인한다. 수정할 View의 component type·Variant와 필요한 spacing·radius 등 외부 layout token만 확인하고, 무관한 컴포넌트·전체 library를 스캔하지 않는다. declaration·consumer가 없거나 적용할 public API가 불명확하면 affected edit 전에 프로젝트 예외 정책을 확인하거나 blocker를 보고한다. literal·source pixel 또는 임의 예외를 만들지 않는다.
- 제공 source, 화면 instance, canonical component source는 다른 근거다. source는 입력 존재, instance는 실제 사용·override, canonical source는 공통 API·Variant·기본값을 증명한다. instance나 스크린샷만으로 public contract를 추정하지 않는다.
- 계획·구현 직전에 실제 Design System의 public component·semantic token 선언과 modifier/Variant consumer를 확인한다. 새 작업은 approval memo에 확인한 declaration·consumer와 선택 또는 미사용 이유를 간결히 남긴다. 별도 조사 문서를 만들지 않는다.
- 색상·간격·크기·corner radius·typography·stroke·shadow·icon을 포함한 모든 제품 visual property와 외부 layout은 제공된 public token/API를 사용한다. Figma 수치나 기존 literal을 새 상수·modifier로 복사하지 않으며, modifier는 실제 consumer에 적용한다.
- 제품은 화면 배치·외부 container·문구·action만 소유한다. public component가 소유하는 내부 height, padding, corner radius, typography, color, icon size, interaction state를 제품 modifier나 상수로 다시 선언하지 않는다.
- public API가 없어서 제품 로컬 metric이 필요한 경우에만 approval memo에 정확한 proposed expression, source, 누락 public-token 이유와 화면-local boundary를 기록한다. 범위 밖 API·Variant·파일·동작이 필요하면 Workplan을 재승인 대상으로 만든다.

## 작업 연결

계획 수집·최종 승인 패킷·재승인은 [Execution Contract](execution-contract.md)를, 외부 티켓은 연결된 [Ticket Lifecycle](ticket-lifecycle.md)를, render/source 적합성은 [UI Verification](ui-verification.md)를 따른다. 이 계약은 lifecycle을 새로 만들지 않으며, literal review는 proposed `swift`/`swiftui` fence의 제한된 call 형태만 확인한다. 한 줄 주석은 제외하지만 문자열·복잡한 Swift 표현을 해석하지 않으므로 완전한 SwiftUI 의미 검증이나 Figma 적합성을 주장하지 않는다.
