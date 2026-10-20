# UI Source Coverage

Figma 같은 외부 디자인 원천으로 화면을 계획·구현할 때 선택 node와 실제 제품 화면 경계를 구분한다. 하위 콘텐츠만 확인한 결과를 전체 화면 계약으로 취급하지 않는다.

## Screen Source Manifest

화면 단위 변경은 다음 항목을 Workplan의 조사·검증 자료에 남긴다.

- `source node role`: `screen`, `container`, `content`, `component`, `state` 중 확인된 역할
- `render root`: 제품에서 실제로 렌더되는 경계와 대응하는 가장 가까운 상위 screen frame
- `source identity`: file, node, revision 또는 확인 시점, state와 logical viewport
- `source reference`: 정확한 source identity에서 LLM이 추출한 원천 이미지와 locale
- `parent chain`: 제공 node에서 render root까지 확인한 계층
- `visible regions`: 위에서 아래, 배경에서 overlay 순서의 화면 영역
- `region mapping`: 각 영역의 source node, 책임 코드·View, 표시 state와 검증 Snapshot
- `excluded regions`: 제외 이유와 실제 소유 계층

선택 node가 전체 screen이 아니고 render root를 확인하지 못했거나, 보이는 영역에 미확인·미매핑 항목이 있으면 `readiness: ready`로 두지 않는다. 모든 Figma 페이지를 전수 조사하지 않고 선택 node에서 render root까지와 그 화면에서 보이는 영역만 확인한다.

수정 파일이 검증 경계를 결정하지 않는다. 배경, overlay, tooltip/popover, Safe Area, z-order, section 간격이나 둘 이상의 visible region 위치 관계를 바꾸면 검증 경계는 해당 View들의 가장 가까운 공통 부모 render root다. 이런 변경을 하위 차트·컴포넌트 crop으로 검증할 수 없다.

단독 컴포넌트 작업은 screen manifest 대신 canonical component source boundary와 Variant 계약을 사용한다.

기능 Workplan의 화면 근거는 별도 문서를 만들지 않고 계획 코드 근거가 있는 `Details/description.md` 또는 `Details/code-plan.md`의 `feature-plan-completeness-v1`에 간결한 coverage 행으로 둔다. source identity·role·reference와 render root를 한 번 기록하고, 필요한 region·state·interaction·navigation·geometry·Preview·Snapshot만 REQ·CODE·TEST ID에 연결한다. 적용되지 않는 항목은 빈 행을 만들지 않고 이유가 있는 `not_applicable` mapping으로 남긴다. 부모는 source kind·locator의 단어가 아니라 실제 화면 계약 필요성을 `requires_ui_context` boolean으로 판정한다. true source가 REQ에 연결된 경우에만 UI Context를 강제하고 explicit N/A source는 강제하지 않는다.

- destination이 있는 navigation은 `mixed` profile과 `flow-navigation` facet을 요구한다.
- 조건에 따라 region·interaction이 달라지는 state는 `state-management` facet을 요구한다.
- 시각 UI는 `ui-system`, 직접 render·Snapshot 검증은 `testing` facet을 요구한다.
- REQ에 연결된 `requires_ui_context: true` source가 있는데 구조화 coverage가 없거나 시각 변경의 geometry·Preview·Snapshot 연결이 끊기면 승인·구현 준비 완료로 판정하지 않는다. `ui`·`mixed` profile만으로 coverage를 강제하지 않으며, 모든 수치나 화면 속성을 기계적으로 전사하지 않고 이번 변경과 직접 관련된 행만 기록한다.

## 구현

- 구현 시작 시 승인된 manifest와 현재 View tree·container 책임을 다시 대조한다.
- 승인된 제외 영역을 임의로 구현하거나, 매핑된 영역을 cleanup 대상으로 삭제하지 않는다.
- 새 영역, 다른 render root 또는 소유 계층이 발견되면 승인 범위를 확인하고 필요한 경우 재승인한다.
- 사용자가 Figma 불일치를 보고하거나 새 Figma 링크를 제공하면 기존 source coverage가 그 source identity·render root·영향 visible region을 포함하는지 먼저 확인한다. 포함하지 않으면 기존 좁은 Snapshot을 실행하거나 코드를 수정하기 전에 coverage를 보충하고 `ui-verification-gate validate --phase plan`을 다시 통과시킨다.

## 검증

- 전체 화면 변경은 manifest의 같은 render root·state·viewport·locale로 source reference와 앱 candidate를 LLM이 생성·대조하고, 원천 적합성이 확인된 앱 candidate를 source-traceable golden으로 승격해 최종 Snapshot과 비교한다.
- 모든 visible region이 source, code와 실제 render 증거에 연결되어야 한다.
- 요구사항이 여러 region의 관계를 포함하면 candidate artifact도 그 모든 region을 한 화면에 포함해야 한다. 예를 들어 날짜 배경·차트·tooltip·범례의 관계는 차트-only crop으로 증명할 수 없다.
- render 성공, 이미지 존재·크기 확인과 attachment 저장은 `smoke`이며 픽셀 회귀 검증이 아니다.
- source-traceable golden과 실제 이미지 차이가 assertion failure를 발생시킬 때만 Snapshot 회귀 검증으로 기록한다.
- canonical 원천이 완전하면 Golden 부재는 사용자 승인 대기가 아니다. LLM이 reference 추출부터 candidate 수정·재렌더·golden 승격까지 수행하며, 원천 상충이나 새 제품 판단이 있을 때만 질문한다.
- 누락 region, 다른 화면 경계, golden assertion 부재 또는 원천 대조 누락이 있으면 `verification_status: blocked`로 기록한다.
