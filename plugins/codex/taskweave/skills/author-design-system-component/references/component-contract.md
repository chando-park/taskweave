# Component Contract

공통 원천 우선순위, public design contract와 티켓 연결 제한은 [Design System Implementation Contract](../../../references/design-system-implementation-contract.md)를 먼저 적용한다.

계획과 결과에 다음 대응 관계를 기록한다.

| 항목 | 확인 내용 |
| --- | --- |
| 대상 저장소 | 디자인 시스템 구현 저장소 여부, 제품 프로젝트와의 구분 |
| 기존 구현 | 동일 컴포넌트 존재 여부, public API, 지원 상태, Preview·테스트 |
| Figma | file, node, component set, revision, variant·property 축 |
| 유사 코드 | 재사용할 component, style/environment modifier, 호출 예시 |
| Public design contract | 외부 제공 semantic token과 public component API, literal 사용 여부, 누락 표현 |
| Token | semantic token 이름, Light/Dark 값, 원천 파일, generator, 생성 결과 |
| 하위 컴포넌트 | 기존 조합 가능 여부, 누락 시 로컬 구현·공통 컴포넌트 추가 결정 |
| SwiftUI API | 최소 init, public modifier, state binding, 접근 제어 |
| 이벤트 | 버튼·선택·닫기 이벤트 전달 API, 제품별 effect 제외 |
| 상태 | normal, pressed, focused, selected, disabled, loading, error 중 해당 상태 |
| Layout | intrinsic size, padding, gap, radius, line limit, Dynamic Type |
| 검증 | Preview/snapshot, interaction test, accessibility, 실행 명령 |

## 생성 계약
- 저장소가 `semantic_lightdark.json → gen_colors.py → color assets + SLColor.swift` 같은 파이프라인을 선언했다면 첫 파일과 generator가 변경 지점이고 뒤의 파일은 생성물이다.
- 실제 저장소에서 경로와 명령을 확인하기 전에는 예시 이름을 그대로 사용하지 않는다.
- 생성물에만 존재하는 값은 원천 누락 또는 generator 결함으로 분류한다.
- Figma와 코드의 scale이 다르면 임의로 합치지 말고 호환 유지, migration, 디자인 수정 중 결정이 필요한 항목으로 남긴다.

## 승인 패킷

목적, Figma 근거, 재사용 관용구, variant/API 매핑, token/codegen 영향, 변경 파일, Preview·테스트, 미확정 질문을 한 화면 분량으로 우선 제시한다. 상세 조사 로그는 반복하지 않는다.
