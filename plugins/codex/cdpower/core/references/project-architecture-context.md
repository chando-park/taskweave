# 프로젝트 아키텍처 근거 선택

기능·버그 계획은 대상 프로젝트의 고유 아키텍처를 `임시 약속`이 아닌 `검증 대상 근거`로 다룹니다. 타입명을 고정하지 않고 책임별로 원천을 선택해 추적합니다.

공통 Runtime은 프로젝트의 구체적인 타입·제품 동작·회사 결정을 소유하지 않습니다. 반복 작성·검증 규범은 Product Memory Standard, 현재 조립과 적용 관계는 System, 선택 이유는 Decision에 둡니다. 별도의 유효한 실행 절차가 있을 때만 Runbook을 읽습니다. Runtime은 프로젝트 resolver가 반환한 원천을 찾고 현재 코드와 대조하는 절차만 정의합니다.

## 현재 요청에서 읽을 순서

resolver가 반환한 Project Agent → 이번 책임 범위에 적용되는 accepted Standard → System의 채택·프로젝트 차이 → 근거 Decision → 해당 작업의 유효한 Runbook이 있을 때만 그 절차 → 현재 기준 구현·테스트 순서로 확인합니다. 전체 원칙을 일괄 정독하지 않으며 구체적인 회사 타입을 개인 Runtime에 복제하지 않습니다. draft는 후보, deprecated·superseded는 이력이지 강제 지침이 아닙니다.

새 `approval-memo-v1`은 [Workplan 작성과 실행](workplan-layout.md)에 따라 main·선택적 승인 코드 Detail에 실제 읽은 원칙·적용 책임·코드 대조·상충과 예외를 연결합니다. 아래 frontmatter와 상세 evidence 필드는 회사 resolver·현재 schema가 요구할 때 사용합니다. 새 개인 메모에 구형 `Details/requirements.md`를 일괄 생성하지 않습니다. 회사 정책의 필수 ID·binding이 누락된 경우는 형식을 줄인다는 이유로 통과시키지 않습니다.

## 해당 정책이 요구하는 근거 필드

- `architecture_context_status`: `verified` | `partial` | `not_applicable`
- `architecture_context_scopes`: 배열, 최소 1개 이상 (검토 책임 범위)
- `architecture_context_sources`: 배열, 원천별 식별자 리스트
- `architecture_context_scope_note`(선택): status가 `partial` 또는 `not_applicable`일 때 선택 사유를 기록

## 책임 범위 분류

- `module-boundary`
- `state-management`
- `flow-navigation`
- `dependency-domain`
- `async-lifecycle`
- `presentation`
- `ui-system`
- `testing`

## 원천 상태와 적용 규칙

- `verified`: 프로젝트 Agent, Product Memory, baseline, 코드·테스트를 대조했고 상충을 해소한 경우.
- `partial`: 중요한 원천 부재/오래됨/상충이 남아 있어 구현 게이트가 필요한 경우.
- `not_applicable`: 실행 코드 변경이 없거나 아키텍처 범위와 무관한 작업이고 사유를 기록한 경우.

`partial` 상태는 구현 준비(`readiness`)가 `ready`일 수 없습니다. `draft` Standard는 후보로 읽되 강제 규범으로 일반화하지 않습니다. `deprecated`·`superseded` Standard를 반환했거나 accepted Standard와 현재 기준 구현이 충돌하면 구현 전 resolver/지식 갱신 또는 재승인을 선행합니다.

## 계획에서 요구되는 기록

새 메모의 main·선택적 Detail, 또는 기존 Workplan의 `Details/requirements.md`에 다음을 필요한 만큼 기록합니다.

- 원천: 프로젝트 Agent 링크, Product Memory ID, baseline ID, 코드 commit 정보
- 상태: accepted/verified/partial/active/draft
- 코드 대조: 현재 코드가 원천 주장에 부합/상충/미확인
- 적용 책임: 이번 변경에서 실제 적용할 scope
- 예외: 기존 구조를 유지해야 하는 이유와 범위

## 변경 범위별 원칙 선택

회사 정책이 `principle_context`를 반환하면 Project Agent를 읽은 뒤 `principle_context_resolver_script principle-context <project-id> <scope...>`를 실행한다. scope는 변경 심볼에서 판정하며 관련 없는 원칙을 모두 읽지 않는다.

- TCA Feature·Reducer: `state-management`; Flow·navigation: `flow-navigation`
- AsyncStream·장기 Effect·취소: `async-lifecycle`
- Alert·sheet·overlay: `presentation`
- SwiftUI·Design System: `ui-system`
- Snapshot·Golden·test harness: `testing`
- 실제 interaction·권한·app lifecycle: `ui-automation`
- API·BLE·저장·Public API: `external-contract`

Workplan에는 다음을 남긴다.

- `principle_context_schema: scoped-v1`: 회사 policy의 principle context가 configured일 때만 선언
- `required_principle_context`: resolver가 선택한 필수 안정 ID
- `architecture_context_evidence`: ID별 `status`, 실제 사용한 `used_claims`, Event·commit 근거와 충돌
- `reference_implementations`: 대상 코드와 별개로 읽은 현재 프로젝트 기준 소비 코드·테스트
- `context_scope_decisions`: scope별 `selected` 또는 `excluded`. 설명이 필요하면 `{ selection: selected|excluded, reason: ... }` 형식

원칙 소비 순서는 위의 현재 요청 읽기 순서를 따른다. 정책이 요구한 필수 ID가 `architecture_context_sources`와 evidence에 모두 없거나, `draft`·`proposal`을 `verified` 정책으로 일반화하거나, Standard와 기준 구현 대조가 없으면 `verified / ready`로 판정하지 않는다. System override는 accepted Decision 근거가 있을 때만 적용한다.

### scoped-v2 근거 연결

회사 policy가 `principle-context-v2`를 제공하면 `principle_context_resolver_script principle-context-v2 <project-id> <scope...> --required-input <generic-input>...`로 선택 scope의 stable `context_id`·`covers_inputs`·상태·local proof를 받는다. 이 JSON을 `resolve-context-pack.rb --contract scoped-v2`의 첫 `--evidence`로, 저장소 규칙·코드·직접 테스트 근거를 담은 plan-local evidence를 두 번째 `--evidence`로 전달한다. resolver는 두 required input 집합의 합집합이 전체 selected Context와 같은지 검사한다. provider가 v2를 지원하지 않으면 회사 경로를 추정하지 않고 제한을 남긴 뒤 확인 가능한 local evidence만 사용하며, 필수 binding이 비면 blocked로 유지한다.

## SwiftUI 파일 경계 게이트

`ui-system` 범위에서 resolver가 View 구조 Standard를 반환하면 Runtime은 그 본문을 복제하지 않고 다음 소비 증거만 요구한다.

- 대상 루트 View 파일과 같은 Feature의 기존 폴더·파일 관례를 함께 읽는다.
- 새로 만들거나 수정하는 이름 있는 하위 View가 독립 입력·레이아웃·상태·수명·Preview·테스트 경계를 가지는지 판정한다.
- Workplan의 영향 파일에 새 파일·이동 파일을 적거나, 같은 파일에 유지하는 이유를 남긴다.
- 구현 diff에서 승인 계획과 다른 하위 View 누적 또는 불필요한 접근 수준 확대가 생기면 완료하지 않고 범위 변경 여부를 판정한다.

실제 분리 기준, 폴더명과 예외는 resolver가 반환한 accepted Standard와 System 채택·override가 소유한다. Runtime은 줄 수나 특정 회사 경로를 공통 상수로 강제하지 않는다.

## 구현 직전 영향받은 근거만 재확인

- 변경 승인 후 구현 직전에 `feature-apply`/`bugfix-apply`에서 아래를 재확인합니다.
  - 현재 코드 대조 결과에 새 상충이 생겼는지
  - `architecture_context_status`와 `readiness`의 정합성
  - scope가 변경되면 승인 범위 갱신 필요 여부

이미 읽은 지침과 유효한 근거를 전체 재수집하지 않습니다. 변경된 코드·원천·범위와 실제 편집할 UI rule leaf·declaration만 확인합니다.

승인 범위가 바뀌면 `needs_reapproval`로 되돌려야 합니다.
