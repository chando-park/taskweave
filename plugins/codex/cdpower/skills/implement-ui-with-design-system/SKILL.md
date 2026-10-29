---
name: implement-ui-with-design-system
description: 현재 승인 feature Workplan의 UI를 실제 디자인 시스템 선언에 따라 구현하고 영향 화면·상태를 검증한다. 공통 apply를 반복하지 않는다.
---

# 디자인 시스템 기반 UI 구현

$cdpower:feature-apply의 같은 승인 Workplan을 사용한다. 공통 approve·apply·Jira 시작 처리를 반복하지 않는다.

## 편집 직전과 필요한 기능

1. [디자인 시스템 계약](../../references/design-system-implementation-contract.md)을 읽고 Project Agent가 지정한 필수 UI rule leaf, 실제 component/token declaration·consumer·external layout 규칙을 확인한다. index·링크 확인만으로 읽음을 대신하거나 원천 픽셀을 임의 literal로 복사하지 않는다.
2. 승인한 public component·token·state/action·상호작용·navigation·현지화 accessor를 사용한다. 새 공통 API는 제품에 발명하지 않는다. 화면-local 조합·metric의 허용 여부는 프로젝트 규칙과 승인 범위로 판단한다.
3. 새·변경 SwiftUI View의 대표 Preview를 유지한다. [UI 검증](../../references/ui-verification.md)에서 승인한 tier·영향 View/state/ID에 필요한 기능의 입력·명령·판정·후속 행동만 읽고 실행한다.

regression은 출처와 identity가 같은 기존 Golden·영향 Snapshot을 사용한다. conformance/full은 독립 원천 이미지와 정확한 대상 worktree의 앱 렌더를 같은 경계·환경으로 대조하고 필요한 상호작용·접근성 테스트를 실행한다.

원천과 렌더가 다르면 승인 범위에서 수정·재렌더한다. 승인 밖 token/API/Variant/state·원천·repository가 필요하면 재승인한다. source → candidate → machine comparison → pre-golden authorization → Golden 승격 → Snapshot 순서를 유지하며 현재 렌더를 먼저 Golden으로 기록하지 않는다. 원천 비교 실패는 property test·Snapshot·build 성공으로 상쇄할 수 없다. 모니터·Canvas·다른 checkout 이미지는 원천 적합성 근거가 아니다.

## 결과 기록

[구현 결과의 빠짐없는 설명](../../references/verification-evidence.md#구현-결과의-빠짐없는-설명)에 따라 이번 UI의 추가·변경·삭제한 타입·함수·조건부 표시·이벤트와 호출 흐름을 실제 코드로 설명하고, 테스트 목록·결과·커버리지 또는 미측정 이유를 상위 구현 결과와 함께 보고한다. 상위 보고가 담당한다는 이유로 이번 UI 변경을 생략하지 않는다.

[Workplan 양식](../../references/workplan-layout.md)에 따라 현재 작업에 실제 UI diff·검토·미실행 범위를 기록한다. 필요한 원천·렌더·비교 결과는 보존하되 schema·role·hash의 형식 검사를 수정·보고의 허가 조건으로 삼지 않는다.

none은 직접 compile/behavior 결과를, 나머지 tier는 실제 source/render/comparison/Snapshot·필요한 interaction 결과를 연결한다. 실제 필요한 검토가 통과했을 때만 awaiting_completion이며 미실행·외부 차단을 구분한다. 원천 대조나 필수 동작 검증 실패를 문서 보완으로 통과시키지 않는다. 같은 성공 결과의 검사를 반복하지 않으며 실제 코드 설명과 최종 종료 권한은 상위 실행 계약을 따른다.
