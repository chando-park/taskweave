# 필요한 작업 근거 선택

## 신규 메모와 기존 Workplan 구분

새 `approval-memo-v1`은 [Workplan 작성과 실행](workplan-layout.md)에 따라 main에 이유·핵심 현재/제안 코드·변경 경계·직접 검증을 두고 긴 승인 코드만 선택적 Detail로 연결한다. profile·facet·읽은 원칙·제외 이유도 필요한 만큼 메모에 적는다. 기존의 `Details/description.md`와 REQ/CODE/TEST 구조화 그래프를 새 메모의 필수 산출물로 만들지 않는다.

아래 선택기·회사 principle resolver가 요구하는 실제 입력·근거 검사는 유지한다. 메모 형식이 짧아졌다는 이유로 required input, 원천 범위, 권한 또는 적용 원칙을 생략하지 않는다. `scoped-v2`는 해당 계약을 실행하는 normal/high-risk 경로, `direct-v1`은 direct 경로에서 필요한 경우 사용한다. 모든 요청에 선택기 실행과 보조 evidence 파일 생성을 반복하지 않는다.

이미 승인된 기존 Workplan의 Details·profile·mapping·gate는 해당 schema대로 유지한다. 기존 필드 안내는 그 문서를 이어갈 때 읽으며 자동 migration하지 않는다.

작업 전 다음 근거를 필요한 만큼만 구성한다.

1. 요청 원문 또는 티켓: 관찰·기대·제약
2. 저장소 규칙: 가까운 `AGENTS.md`, 빌드·테스트 안내
3. 코드: 진입점, 직접 호출 흐름, 관련 상태와 오류 경로
4. 테스트: 직접 회귀 테스트와 실행 명령
5. 외부 원천: 판단에 필요한 Figma·API·기획·팀 지식의 정확한 위치
6. 변경 경계: 대상 파일·저장소와 변경하지 않을 영역, [Repository Artifact Boundary](repository-artifact-boundary.md)에 따른 산출물 목적지와 계획 시점 diff baseline

광범위한 위키, Git 전체 이력, 모든 Figma 화면을 기본으로 읽지 않는다. 결론을 바꾸는 정보가 부족할 때만 확장한다. 원문 사실, 코드 사실, 추론, 확인 필요, 사람 결정을 표시한다.

## 정본과 단계별 읽기

| 판단 | 정본 | 읽는 시점 | 남기는 결과 |
| --- | --- | --- | --- |
| 실행 순서·승인 의미 | [Execution Contract](execution-contract.md) | 요청 분류와 승인 응답 해석 때 | route, 승인 범위와 다음 단계 |
| 개인·회사 경계와 동적 Agent | [Company Workplan Adapter](company-workplan-adapter.md), [Project Architecture Context](project-architecture-context.md) | 저장소 식별 직후, 회사 작업일 때만 | resolver가 반환한 Agent·정책 경로 |
| profile·facet | [context-profiles.yaml](context-profiles.yaml) | 계획 조사 범위를 고르기 전 | 선택·제외 Context와 이유 |
| Jira 상태 전환 | [Ticket Lifecycle](ticket-lifecycle.md) | 회사 계획 생성·구현 시작·완료 시점 | 확인된 ticket·상태와 실패 지점 |
| 검증 준비·실행 증거 | [Verification Planning](verification-planning.md), [Verification Evidence](verification-evidence.md) | 계획 때 준비하고 실행·인계 때 증거 확인 | preflight packet과 재사용 가능한 결과 |
| 승인 후 피드백 | [Acceptance Feedback Loop](acceptance-feedback-loop.md) | 구현·검증·완료 대기 중 피드백이 왔을 때만 | correction·scope change·독립 이슈 분류 |
| UI 수정 직전 Design System 읽기 | [Design System Implementation Contract](design-system-implementation-contract.md)와 Agent/Context Pack이 가리키는 필수 UI rule leaf | direct fix·apply·feedback에서 실제 View를 편집하기 직전 | 확인한 관련 declaration·consumer·layout rule 또는 프로젝트 예외 |
| 코드 symbol·caller·implementation 탐색 | [Serena Code Intelligence](serena-code-intelligence.md) | 프로젝트 기준선·계획 조사와 semantic 코드 편집 직전 | 실제 symbol·caller와 Serena 사용 근거 또는 연결 차단 |

계획은 선택된 profile과 실제 변경 경계에 필요한 원천만 읽는다. 승인은 [승인 경로 선택](execution-contract.md#승인-경로-선택)에 따라 기록하며 상세 원천을 다시 조사하지 않는다. 구현은 승인 메모·선택적 Detail과 유효한 Context를 재사용하고, 현재 상태가 달라진 항목만 좁게 확인한다. UI 편집 직전 rule leaf·실제 declaration 확인은 별도로 지킨다. 검증과 완료는 각각 필요한 실행 증거를 소비하며 앞 단계 조사를 반복하지 않는다. 선택한 문서는 끝까지 읽되 표의 모든 정본을 일괄 로드하지 않는다.

## 기능 Context profile

신규 제품 기능은 `/taskweave:feature-plan`이 다음 중 하나를 의미로 판정하고, 결정론적 선택기로 결과를 검증한다.

```bash
"${AI_RUNTIME_BIN:-$HOME/.codex/bin}/resolve-context-pack" \
  --profile logic|ui|mixed [--facet external-contract]
```

단일 원본은 [context-profiles.yaml](context-profiles.yaml)이다.

| profile | 반드시 읽는 범위 | 기본 제외 |
| --- | --- | --- |
| `logic` | 기능 진입점, 직접 호출 흐름, 상태·오류, 직접 테스트 | Figma, Design System 상세, Preview·render |
| `ui` | 정확한 Figma node/state, [UI Source Coverage](ui-source-coverage.md)의 render root·visible region, 대상 View, public design contract, 직접 UI 상태·이벤트, Preview·render | 무관한 도메인 흐름과 외부 계약 |
| `mixed` | `logic`과 `ui`의 합집합 | 요청과 무관한 프로젝트 영역 |

- API, BLE/FW, 저장 형식 또는 Public API가 실제 변경 경계면 `external-contract` facet을 명시적으로 추가하고 정확한 계약 종류와 범위를 Workplan에 적는다.
- UI 이벤트가 도메인 상태·API 흐름까지 직접 바꾸면 `ui`로 축소하지 않고 `mixed` 또는 `external-contract`를 선택한다.
- destination·navigation이 있으면 `mixed + flow-navigation`, 조건부 state 전이가 있으면 `state-management`, 시각 UI와 Preview·Snapshot 검증이 있으면 `ui-system + testing` facet을 선택한다. 해당 조건이 없는 순수 `logic` 기능에 UI facet이나 화면 source coverage를 관성적으로 요구하지 않는다.
- Figma 선택 node가 screen이 아니면 `ui-source-coverage.md`의 Screen Source Manifest로 실제 render root와 모든 visible region을 확인한다. 미확인 영역을 둔 채 UI Context가 완성됐다고 판정하지 않는다.
- 기존 구조화 feature Workplan은 `feature-plan-gate validate`가 요구사항 ID, CODE ID, 파일·심볼, 현재 코드 또는 정확한 삽입 지점, 제안 코드, caller, State·Action·Effect·Delegate·Flow, 직접 테스트 mapping을 검증한다. 새 메모는 같은 실질 변경 방향과 검증을 main·선택적 Detail에 쓰고 `workplan-memo`의 승인 검사를 사용한다. 구형 gate를 추가 실행하지 않는다.
- 새 메모는 선택·제외 범위를 main에, 기존 Workplan은 `Details/description.md`에 profile·facet·선택/제외 이유를 기록한다.
- 구현 단계는 승인된 선택을 재사용한다. 새 사실이 profile·facet 또는 주요 변경 경계를 바꾸면 재승인한다.
- 기존 Workplan은 main의 `detail_documents`에서 현재 단계에 필요한 역할만 연다. 현황은 main, 구현은 관련 `description`·`code_plan`·`requirements`, 검증은 관련 `test_plan`·`change`·`verification`이다. 새 메모에 이 세트를 생성하지 않으며 어느 경우든 디렉터리 전체를 선행 로드하지 않는다.

### 신규 계획의 scoped-v2 선택

기존 `--profile`만의 출력은 완료된 Workplan 호환을 위해 그대로 유지한다. 신규 기능·버그 계획은 최초 승인안을 정리할 때 다음 explicit mode를 한 번 실행한다. 승인 응답 기록·승인 후 피드백에서 동일 자료를 다시 수집하지 않고, 원천·범위·검증 입력이 바뀐 때만 갱신한다.

```bash
"${AI_RUNTIME_BIN:-$HOME/.codex/bin}/resolve-context-pack" \
  --contract scoped-v2 --profile <profile> --facet <facet> \
  --repository <Git-root> --evidence <context-evidence.yml> \
  --impact logic \
  --exclude-impact visual='<구체적 제외 이유>' \
  --exclude-impact interaction='<구체적 제외 이유>' \
  --exclude-impact async='<구체적 제외 이유>' \
  --exclude-impact external='<구체적 제외 이유>'
```

- `context-evidence-v2`는 resolver가 선택한 `required_inputs` 전체와 stable `context_id`, `covers_inputs`, `applicability(required|optional|excluded)`, `discovery(confirmed|not_investigated|access_blocked|not_found)`, `authority`, `checked_scopes`, `locator`, `proof`를 둔다. authority와 discovery는 서로 대체하지 않는다. `--evidence`는 반복할 수 있고 회사 `principle-context-v2` JSON과 plan-local evidence를 합쳐 전체 required input을 대조한다.
- local confirmed는 실제 파일과 SHA-256를 대조한다. remote confirmed는 reference와 로컬에 보존된 proof artifact의 SHA-256를 대조한다. 이는 파일 존재·무결성 근거이며 authority·내용 진위·의미 적합성의 자동 검증이 아니다.
- required binding이 비거나 discovery가 confirmed가 아니면 `context_decision.status: blocked`와 gap을 JSON으로 출력하고 exit 3으로 종료한다. optional gap은 따로 남기되 ready를 막지 않는다.
- impact는 `logic|visual|interaction|async|external`를 선택하거나 각각 구체적 이유로 제외한다. visual은 `ui|mixed + ui-system + visual-testing`, interaction은 `ui|mixed + ui-automation`, async는 `async-lifecycle`, external은 `external-contract`와 모순되지 않아야 한다. interaction은 Snapshot으로 대체하지 않는다.
- 선택 결과는 요청 의미를 자동 판정하거나 TEST mapping의 의미를 증명하지 않는다. planner가 선택한 최소 evidence를 실제 test plan에 연결하며, 기존 evidence는 [검증 근거](verification-evidence.md)의 입력·환경·대상 재사용 조건이 같을 때만 유지한다.

### direct-v1 선택

direct route는 현재 영향만 선택해 작은 수정의 반복 제외 사유를 없앤다.

```bash
"${AI_RUNTIME_BIN:-$HOME/.codex/bin}/resolve-context-pack" \
  --contract direct-v1 --profile logic --impact logic
```

- 하나 이상의 실제 impact가 필수이며, 선택하지 않은 impact는 `omitted_by_direct_route`로 기계 기록된다.
- visual은 기존 `ui|mixed + ui-system + visual-testing` facet 조건을 그대로 따른다.
- external/Public API/저장 형식/보안·의료/다중 저장소는 direct route가 아니며 [Risk Routing](risk-routing.md)으로 되돌린다.
- `scoped-v2`의 evidence와 모든 impact 선택·구체적 제외 사유 계약은 normal/high-risk에 그대로 유지된다.

## 근거 커버리지

- planning agent에 위임할 때 부모는 요청·직접 제공된 티켓·URL·첨부·디자인/API 원천과 확인 범위를 전달한다. 기존 구조화 feature gate 경로에서는 expected source inventory, source별 `requires_ui_context`, canonical digest와 hashed requirements의 SOURCE ID를 대조하며 planner가 이 입력을 수정하지 못한다. 새 메모에는 실제 필요한 원천·조회 범위·누락을 짧게 연결하고 구형 hash용 문서 세트를 만들지 않는다. 대화·첨부를 자동 열거할 수 없는 환경에서는 부모의 직접 확인이 필요하다는 제한을 숨기지 않는다.
- 사용자가 제공한 첨부, URL, 인용문과 상위 Workplan·Investigation이 직접 연결한 원천은 조사 수준과 무관하게 먼저 확인한다.
- 원천마다 확인 상태, 근거 역할, 실제 조회 범위, 지지 주장·반대 사례를 짧게 기록한다.
- 근거 역할은 `정의·기본값`, `가이드·허용 예시`, `실제 관찰·인스턴스`, `현재 구현`, `검증`으로 구분한다.
- 선택 node, 일부 페이지, 일부 로그 시간대처럼 부분 범위만 확인했으면 부분 범위를 전체 계약으로 일반화하지 않는다. 결론을 바꿀 수 있는 부모·주변 맥락까지만 확장한다.
- 서로 다른 근거가 상충하면 하나를 버리지 않고 기본값, 허용 범위와 실제 사용의 차이인지 먼저 분리한다.
- 결론을 바꿀 중요 원천을 확인하지 못했거나 상충을 설명하지 못하면 확정 사실이나 높은 확신도로 표시하지 않는다.
