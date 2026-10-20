# UI 원천 대조와 화면 회귀 검증

최종 픽셀에 영향을 주는 UI 변경을 위험에 비례해 검증하는 계약이다. Figma 원천 적합성과 Snapshot 회귀는 구분하되, 이미 검증된 원천 적합성을 매번 다시 만들지 않는다. 전체 화면의 원천 범위는 필요한 단계에서만 [UI Source Coverage](ui-source-coverage.md)로 확정한다.

처음 읽는 사람에게 source/reference는 독립 Figma 원천 이미지, candidate는 실제 수정한 앱의 렌더 이미지다. gate는 이 근거로 필수 조건을 확인하는 도구다. 선택한 tier의 필수 조건은 모두 적용하되 무관한 화면이나 검증을 추가하지 않는다.

이 문서의 원천·렌더·Golden·상호작용 판정은 플랫폼 공통이다. 기기·실행 도구·기본 viewport는 변경 플랫폼의 [Apple 검증](verification-apple.md) 또는 [Android 검증](verification-android.md)에서 선택한다. Android에는 iPhone viewport나 Swift Snapshot 도구를 요구하지 않는다. Compose·Views·SwiftUI Preview도 실제 원천 대조나 동작 테스트를 자동으로 대신하지 않는다.

## 필요한 기능 찾기

| 필요한 기능 | 입력 | 실행·판정 위치 | 다음 행동 |
| --- | --- | --- | --- |
| 검증 단계 선택 | 시각 변경 의도·영향 상태·Golden 출처 | [검증 단계 선택](#검증-단계-선택) | none/regression/conformance/full 중 적용 경로만 선택 |
| 원천 대조 | 독립 Figma 이미지·같은 경계/환경의 현재 worktree 앱 렌더 | [구조화 실행 증거](#구조화-실행-증거)의 source·candidate 등록과 ui-image-compare | 승인 범위 불일치 수정 → 영향 상태 재렌더 |
| Snapshot 회귀 | 출처가 확인된 Golden·영향 ID·실제 실행 결과 | [실행 최소화](#실행-최소화)와 [판정](#판정) | 실패 ID만 수정·재실행, 유효 결과 재사용 |
| Golden 승격 | 통과한 원천 대조·허용 candidate·대상 경로 | [원천 적합성과 Golden](#원천-적합성과-golden), pre-golden·completion | 허용된 candidate만 승격하고 영향 회귀 확인 |
| 상호작용 | tap/drag/scroll 기대 결과·실제 test ID | [계획](#계획)과 Interaction 실행 증거 | 이미지 성공을 동작 성공으로 대신하지 않음 |
| 결과 보고 | 실제 diff·증거·미실행 범위 | [Workplan 작성과 실행](workplan-layout.md), [사용자 상태 보고](execution-contract.md#사용자-상태-보고) | result 기록; 최종 종료는 사용자 완료 요청 뒤 |

## 현재 양식의 기록 위치

새 `approval-memo-v1`은 [Workplan 작성과 실행](workplan-layout.md)의 짧은 메모·실행 artifact 경로를 사용한다. 계획 시 tier·영향 상태·독립 원천·비교/통과 조건을 먼저 고정한다. none이 아닌 tier의 현재 UI parser는 canonical inventory와 계획 packet을 승인 전에 실제로 검사하므로 이 입력을 생략하지 않는다. `detail_documents`의 역할은 parser가 읽을 위치 지정이지 서로 다른 Details 파일 세트 생성 지시가 아니다.

계획 자료는 승인 내용에 포함해 고정하고 parser가 읽는 역할 경로로 연결한다. 구현·검증 뒤에는 `Artifacts/ui-verification.md` 하나에 승인 inventory·계획·실행 증거를 연결할 수 있다. receipt와 이미지·실제 테스트 결과는 별도 Artifacts에 둔다. 검사 대상 입력을 바꾸는 경우에는 해당 단계부터 재확인한다. 아래 기존 Details 위치는 기존 Workplan을 계속할 때만 사용하며 신규 메모로 migration하지 않는다.

## 검증 단계 선택

계획에는 `ui_verification_tier`와 선택 근거를 기록한다.

| 단계 | 적용 조건 | 필수 증거 |
| --- | --- | --- |
| `none` | View의 시각 계약은 그대로이고 UI 출력에 영향이 없거나, 표시 데이터만 바뀌며 Snapshot 제외가 승인됨 | 직접 behavior test 또는 영향 target compile 실행 증거. 표시 데이터 변경은 값·상태 테스트와 사용자 화면 확인도 기록 |
| `regression` | 픽셀은 바뀌면 안 되며 동일 원천·render 경계의 유효한 source-traceable Golden이 **이미** 있음 | 영향받은 Snapshot ID만 실행해 기존 Golden과 비교 |
| `conformance` | 제한된 View·state의 픽셀을 의도적으로 변경 | 바뀐 Figma node/state와 candidate 대조, 영향받은 Snapshot만 갱신·실행 |
| `full` | 새 화면·새 공통 컴포넌트·새 Variant, Figma revision·화면 경계·viewport 계약 변경 | source manifest, visible region coverage, 대표·경계 상태의 원천 대조와 Snapshot |

- 정보가 부족해 단계를 판정할 수 없으면 한 단계 높이거나 `blocked`로 두되 무관한 화면 전체로 자동 확대하지 않는다.
- UI source를 읽기 전에 작업이 View·스타일·레이아웃·표시 조건을 바꾸는지, 데이터 값만 바꾸는지 확인한다. 데이터 전용 변경에서 Snapshot 제외가 승인됐다면 `none`으로 기록하고 Golden을 요구하지 않는다. 값과 상태는 직접 테스트로, 실제 화면 확인을 수행했다면 그 결과를 별도로 기록한다. 화면 확인을 자동 Snapshot 통과로 바꾸어 적지 않는다.
- Snapshot이 필요하다고 판단했으면 승인 전에 기존 Golden과 원천 출처가 있는지 확인한다. 없으면 `regression`으로 승인하지 않고 제공된 Figma URL이나 프로젝트가 연결한 정확한 원본 node를 찾아 Figma 원천→현재 앱 candidate 직접 대조가 필요한 `conformance`로 계획한다. 원본을 찾지 못한 경우에만 필요한 URL·node를 요청하며 Golden 부재만을 완료 단계의 실패로 미루지 않는다.
- 새 Design System public component·Variant는 기본 `full`이다. 기존 검증 범위 안의 내부 리팩터링은 근거가 있으면 `regression` 또는 `none`이다.
- 계획에는 `visual_change_intent`, `source_revision_status`, `affected_render_roots`, `affected_states`, `affected_snapshot_ids`, `project_generation_required`, `separate_compile_required`를 기록한다.

## 계획

- 대상 View, 영향 state, viewport, scale, locale, color scheme, Dynamic Type, safe area, OS·toolchain, fixture와 실행 명령을 기록한다.
- 제품 전체 화면 viewport는 플랫폼 지침과 프로젝트의 승인된 기기·크기·scale을 사용한다. 단독 컴포넌트에는 phone viewport를 강제하지 않는다.
- 색·문구·간격·레이아웃·표시 조건·locale·Variant에 영향이 없으면 `none`으로 분류하고 Snapshot을 요구하지 않는다. 화면에 보이는 데이터 값만 바뀌어도 Snapshot 제외가 승인됐고 값·상태 직접 테스트가 완료 조건이면 `none`을 사용할 수 있다. View 코드나 시각 계약이 바뀌는 작업을 데이터 전용으로 위장하지 않는다.
- `none`은 계획 gate에서 문자열 `ui_verification_reason`만 기록한다. completion gate에서는 실제 성공한 compile·behavior JSON result의 locator/hash도 필요하다. boolean이나 문자열이 아닌 false 값은 사유가 아니다.
- `regression`·`conformance`·`full`은 승인 hash에 포함되는 별도 `canonical-visual-requirements-v1` inventory를 requirements/description에 둔다. source ID와 Figma identity·export hash, REQ별 assertion ID·region/property/source expected/tolerance를 고정하고 frontmatter의 `visual_requirement_inventory_digest`와 대조한다. 새 approval memo는 승인 전에 `ui-verification-gate plan`을 통과해야 하므로 Golden이 없는 `regression`은 그때 차단한다.
- Figma source는 `source_kind: figma`, `node_scope: full-render-boundary | component-boundary`, `coverage_complete: true`, `visible_region_ids`를 선언한다. source receipt는 `provider: figma`, `export_mode: original-node`, `transform: none`을 가져야 한다. 현재 앱 render·기존 Golden·임의 crop·배경만 선택한 노드는 Figma source로 등록할 수 없으며, 모든 visible region은 최소 하나의 assertion과 정확히 연결돼야 한다.
- UI 계획 packet은 canonical inventory digest·source IDs·REQ/assertion IDs·`approved_snapshot_ids`를 그대로 참조한다. 내부 plot·axis·inset 요구를 outer frame 하나로 축소하거나 packet 안에서 자기선언한 assertion으로 바꾸면 실패한다.
- 드래그·스크롤·터치·navigation처럼 이미지로 증명할 수 없는 요구사항은 inventory의 `interactions`에 source, trigger, expected effect와 실제 test ID를 기록하고 계획의 `approved_interaction_test_ids`에 연결한다. 정적 Snapshot ID로 대체할 수 없다.

계획 packet은 새 메모에서는 위의 역할 경로, 기존 Workplan에서는 `Details/test-plan.md`(compact이면 `Details/description.md`)의 `## UI 적합성 계획 (`ui-conformance-evidence-v1`)` 아래 YAML root `ui_conformance_plan`으로 둔다. `ui-verification-gate validate --phase plan <Workplan>`이 승인 질문 전에 이를 검사한다. 새 메모의 `workplan-memo validate --phase approval`은 이 UI 검사를 내부에서 실행하므로 성공한 동일 입력에 별도로 반복하지 않는다.

## 원천 적합성과 Golden

- `source reference`는 정확한 Figma file·node·revision·state·locale에서 추출한 원천 이미지이고, `candidate`는 같은 경계와 환경에서 렌더한 앱 이미지다.
- candidate는 수정 대상의 정확한 Git worktree root에서 렌더한다. render receipt와 gate receipt는 worktree real path·Git dir·HEAD를 결속하며, 다른 checkout/worktree의 빌드·캡처는 같은 브랜치여도 현재 작업의 증거가 아니다.
- 독립 source는 candidate를 생성하기 전에 gate에 등록한다. source receipt/state의 `issued_at_ns`보다 candidate 이미지와 render receipt의 filesystem mtime이 뒤여야 한다. 같은 conformance operation에서 현재 앱 candidate, 그 복사본 또는 candidate operation을 source/reference 역할로 재사용하지 않는다. source와 candidate는 정규화된 서로 다른 path와 physical `dev+inode` identity·gate operation·role provenance를 가져야 하며 locator alias와 hardlink도 같은 artifact로 판정한다. 독립적으로 생성된 서로 다른 artifact의 바이트 hash가 우연히 같은 것은 허용한다.
- Figma export 자체를 앱 Golden으로 사용하지 않는다. 원천과 대조해 적합성이 확인된 앱 candidate만 `source-traceable golden`으로 승격한다.
- Golden의 source file·node·revision·state, render boundary, viewport·locale·환경이 현재 작업과 같으면 기존 원천 적합성 증거는 유효하다. `regression`에서는 Figma 재조회·reference 재생성·수동 재대조를 반복하지 않는다.
- 위 identity가 바뀌거나 누락·상충하면 기존 Golden을 재사용하지 않고 `conformance` 또는 `full`로 올린다.
- canonical 원천이 완전한 `conformance`·`full` 작업은 LLM이 reference 추출, candidate 렌더, 차이 수정과 재렌더, Golden 승격까지 수행한다. Golden 부재만으로 사용자 승인을 요구하지 않는다.
- 원천 상충, 불명확한 상태·경계, 구현 불가능한 제약, tolerance나 의도적 차이처럼 새 제품 판단이 필요할 때만 질문한다.
- baseline 변경에는 이유, 원천 revision, reference, candidate와 before/after baseline diff를 남긴다. 테스트 통과 목적의 자동 record·무검토 덮어쓰기를 금지한다.
- Golden은 `pre-golden` authorization이 발급된 candidate만 승격한다. 일반 구현·Snapshot record 명령으로 현재 render를 곧바로 Golden에 쓰는 경로는 허용하지 않는다.
- 사용자가 현재 화면이 Figma와 다르다고 보고한 상태는 기존 Golden의 원천 적합성이 반증된 것이다. 해당 View·state의 Golden과 이전 `passed` 판정을 즉시 무효로 하고 `regression`을 금지한다. 정확한 Figma source와 새 candidate의 `conformance`를 다시 통과한 뒤에만 Golden을 재승격한다.

## 구조화 실행 증거

`conformance`·`full`은 새 메모의 `Artifacts/ui-verification.md`, 또는 기존 Workplan의 `Details/verification.md`에 `## UI 적합성 증거 (`ui-conformance-evidence-v1`)` 아래 YAML root `ui_conformance_evidence`를 둔다. schema와 parser가 정확히 읽는 packet 제목·필드·명령은 번역하지 않고 그 아래 해설은 한글로 작성한다.

- UI 버그 또는 `repository-feedback-baseline.json`이 있는 승인 후 보정은 `pre_fix`에 수정 전 render·receipt·Figma 비교 report를 둔다. gate는 같은 Figma source와의 비교가 실제 `failed`인지, 수정 후 candidate보다 먼저 생성됐는지 확인한다. 이미 캡처한 실패는 `ui-pre-fix-render-receipt-v2`가 같은 worktree/Git dir, post-fix candidate와 같은 render environment, 변경되지 않은 tests/config/environment와 해당 dependency/resource의 실제 hash를 증명할 때 재사용한다. source hash·boundary·실패 PNG 재계산·시간 순서는 항상 다시 검사하며, 이 범위 증거가 없는 legacy receipt는 현재 HEAD와 정확히 같아야 한다. 수정 전 실패 증거가 없다는 자기선언만으로 post-fix candidate를 등록하지 않는다.
- source export: image artifact/hash와 `ui-source-export-receipt-v1` JSON. receipt는 inventory digest·source/REQ/assertion IDs를 참조한다. self-authored receipt만으로는 부족하며 candidate 생성 전에 `source` phase가 발급한 Runtime state-backed source registration을 evidence에 연결한다.
- candidate render: artifact/hash와 `ui-candidate-render-receipt-v1` JSON. source hash, boundary/state/viewport, author, REQ/assertion IDs와 `repository_identity`를 참조한다. `ui-verification-gate repository-identity --repository <Git-root>`의 출력을 receipt에 넣고, `candidate` phase가 현재 identity와 대조해 별도 registration을 발급한다.
- visual assertion: 계획 ID·REQ·`region/property/source_expected/candidate_actual/tolerance/result`
- comparison과 독립 review: 각각 구조화 JSON receipt가 source/candidate/comparison hash, inventory digest, boundary/state/viewport와 전체 REQ/assertion IDs를 상호 참조한다. 임의 텍스트 파일과 `result: passed` 문자열만으로 통과하지 않는다.
- machine image comparison: `ui-image-compare`가 동일 raster의 source/candidate PNG를 직접 읽어 크기, 변경 픽셀 비율, 평균·최대 색상 차이를 계산한 `ui-image-comparison-v1`을 생성한다. `ui-verification-gate`는 실제 PNG에서 결과를 다시 계산하며 보고서가 없거나 값이 다르거나 허용 범위를 넘으면 Golden 승격을 차단한다. 비교 tolerance는 Runtime 상한을 넘길 수 없다.
- Snapshot: command와 packet count 외에 parser 종류, 실제 JUnit/XML 또는 `snapshot-result-v1` JSON artifact/hash, 승인 snapshot IDs를 기록한다. gate가 testcase ID·실행 건수·실패·exit status를 직접 파싱해 packet과 대조한다. 일부 ID만 다시 실행할 때는 `snapshot-evidence-set-v2`의 `fresh_results`와 `reused_results`를 합쳐 승인 ID 전체를 중복 없이 채운다. 각 result는 같은 Snapshot ID를 `subject_ids`로 가진 scoped `verification-plan` evidence와 실제 result artifact/hash가 같아야 한다.
- Interaction: 계획에 interaction이 있으면 `ui-interaction-result-v1` artifact의 test IDs·실행 건수·failure·exit status를 별도로 검사한다. Snapshot 통과를 drag·tap·scroll 성공으로 확대 해석하지 않는다.
- Golden provenance: pre-golden은 등록된 source/candidate operation, 실제 comparison·assertion evidence와 정규화된 Golden destination identity를 결속한 승격 authorization을 발급한다. 미존재 destination은 가장 가까운 기존 조상까지 해석해 bundle 안인지 확인하고 symlink 조상이 있으면 거부한다. completion은 같은 destination에 승격된 Golden만 허용하고 authorization의 candidate hash와 실제 Golden hash를 결속한 `source-traceable-golden-gate-receipt-v2`를 발급한다. 모든 gate receipt는 무작위 operation ID와 Workplan·repository 밖 Runtime-owned state가 있어야 하며 gate 모양의 self-authored receipt는 거부한다.

source export 직후 `source`를 실행할 수 있다. app candidate 생성 전에는 승인 범위의 제품 구현을 끝내되 설명 문서의 형식 보수를 렌더의 선행 조건으로 삼지 않는다. `implementation-explanation-gate`는 `completion`에서 최종 diff와 설명을 대조한다. `candidate`·`pre-golden`은 독립 원천·실제 렌더·비교 증거를 계속 검사하며 설명 검사 이동을 원천 대조 생략으로 해석하지 않는다. app render 직후 `candidate`, Golden 승격 직전 `pre-golden`을 순서대로 실행하고 출력 artifact/hash를 기록한다. pre-golden authorization 전에 Golden 파일을 쓰거나 복사하면 실패한다. 승격 뒤 `completion --issue-receipt`가 Golden provenance를 발급한다. completion은 issuer/version, Runtime state, payload digest, authorization candidate와 promoted Golden hash, 재실행 Snapshot의 1건 이상·0 failure·exit status 0을 다시 검증한다. JUnit skipped/disabled는 실행 건수에서 제외되고 승인 Snapshot ID가 skip이면 실패하며 JSON/JUnit 모두 중복 없는 test ID 수와 실행 건수가 같아야 한다.

`regression`은 canonical inventory에 연결된 source-traceable Golden JSON receipt가 계획 packet에 있어야 하며 completion에서 영향 snapshot ID별 실제 JUnit/JSON result를 반드시 실행한다. Golden identity나 실제 결과가 없으면 상위 tier 또는 verification blocked다.

```bash
ui-verification-gate validate --phase plan <Workplan>
ui-verification-gate validate --phase source --issue-receipt Artifacts/ui-source-registration.json <Workplan>
ui-verification-gate repository-identity --repository <Git-root>
ui-verification-gate validate --phase candidate --repository <Git-root> --issue-receipt Artifacts/ui-candidate-registration.json <Workplan>
ui-image-compare --source <Figma-source.png> --candidate <app-render.png> --output Artifacts/ui-image-comparison.json
ui-verification-gate validate --phase pre-golden --repository <Git-root> --issue-receipt Artifacts/ui-pre-golden-receipt.json <Workplan>
ui-verification-gate validate --phase completion --repository <Git-root> --issue-receipt Artifacts/ui-golden-provenance.json <Workplan>
```

게이트는 전체 이미지 차이를 기계적으로 재계산하지만 이미지의 의미나 Figma 의도를 100% 자동 해석하지 못한다. 작은 아이콘·구분선처럼 전체 픽셀 비율에 묻힐 수 있는 차이를 보완하기 위해 모든 `conformance`·`full`은 source와 candidate를 독립적으로 읽은 review artifact도 필수로 둔다. 좁은 보정은 같은 registered source·render root·visible region 안에서만 지적된 View·state로 제한한다. overlay/background·Safe Area·z-order·형제 region 위치 관계 또는 새 Figma source가 걸리면 가장 가까운 공통 render root로 올리고 source coverage를 다시 확인한다. self-authored 문자열만으로 원천 적합성을 증명하지 않는다.

Runtime state record는 정상 작업 흐름에서 독립 source 선행 등록, source/candidate role 분리, comparison 후 승격 authorization, authorized candidate→Golden 결속을 강제하는 process-integrity 장치다. regression은 이 gate-issued conformance provenance와 변경되지 않은 Golden만 재사용한다. 같은 사용자 권한으로 Runtime state와 Workplan을 함께 변조하는 적대적 보안 경계나 암호학적 서명으로 취급하지 않는다.

## 실행 최소화

- 수정한 View와 직접 연결된 `affected_snapshot_ids`부터 실행한다. 무관한 locale·상태·화면의 전체 Snapshot suite는 기본 실행하지 않는다.
- 관련 source/test/config/environment 및 사용하는 dependency/resource 파일을 모두 hash 입력으로 기록한 scoped evidence만 재사용한다. `verification-plan prepare`에 Snapshot별 `--subject-id`와 `environment:` input을 주며, 누락 없는 영향 범위를 자동 추론했다고 보지 않는다. 해당 입력이 그대로면 HEAD만 바뀐 커밋 뒤에도 기존 result와 source-traceable Golden을 재사용할 수 있고, 새로 실행할 영향 ID가 없으면 `fresh_results`는 비워 둔다. 입력 범위가 없거나 하나라도 바뀌면 legacy strict 경로를 유지하거나 그 ID만 다시 실행한다.
- Snapshot과 behavior test가 같은 simulator UDID, workspace, DerivedData 또는 artifact 디렉터리를 공유하면 직렬 실행한다. 병렬화하려면 각 자원을 모두 분리하고 프로젝트 도구의 동시 실행 지원을 확인한다.
- Tuist manifest, resource, scheme, dependency graph가 바뀌었거나 workspace가 없고 생성 없이는 직접 test를 실행할 수 있을 때만 프로젝트를 재생성한다.
- Snapshot test가 실제 영향 target을 같은 configuration으로 컴파일했다면 그 실행을 compile 증거로 재사용한다. 다른 target·configuration·link 계약을 확인해야 할 때만 별도 build를 실행한다.
- behavior가 바뀌지 않은 시각 변경에는 전체 unit suite를 요구하지 않는다. 반대로 behavior 변경은 Snapshot으로 대체하지 않는다.
- 영향 ID 밖의 기존 실패는 별도 위험으로 기록하되 현재 변경의 검증 범위를 자동 확대하지 않는다.
- runner·simulator 문제로 일부 Snapshot만 미실행되면 완료된 ID를 포함한 전체 묶음을 반복하지 않고 실패하거나 미실행된 영향 ID만 다시 실행한다.
- 전체 feature/app suite는 교차 모듈 영향, MR·CI·release gate 또는 사용자의 명시 요청에서 실행한다.

## 비교 가능성

- source와 render의 node scope, state, viewport, locale, logical size, aspect ratio와 scale을 먼저 맞춘다.
- 전체 화면은 상태바·navigation·safe area·overlay를 포함한 screen frame끼리 비교한다. 일부 Contents와 전체 화면 Snapshot을 직접 비교하지 않는다.
- `thumbnail`, 임의 여백, 다른 비율의 stretch로 경계 차이를 감추지 않는다. 동일 비율 변환만 허용하고 변환식을 기록한다.
- 문구와 색뿐 아니라 typography, text decoration, icon, geometry, spacing, visibility와 state를 대조한다.

## 판정

- Figma conformance는 Golden이 원천에 맞는지 증명하고, Snapshot regression은 현재 render가 그 Golden과 같은지 증명한다. `regression`은 유효한 기존 conformance 증거를 재사용한다.
- Snapshot 또는 Golden 비교 성공만으로 Figma 적합성을 보고할 수 없다. `conformance`·`full`의 source→candidate 직접 대조가 선행되지 않은 앱 렌더 Golden은 자기확인형 baseline이며 완료 근거가 아니다.
- screenshot attachment, render 성공, 이미지 존재·크기 확인은 `smoke`다. Golden pixel assertion을 대신하지 않는다.
- source-traceable Golden과 실제 render 차이가 assertion failure를 발생시킬 때만 Snapshot Test로 기록한다.
- Preview·Simulator·XCUITest screenshot은 보조 근거다. 모니터 전체 화면이나 Xcode Canvas 캡처는 완료 근거가 아니다.
- Figma와 render의 차이는 승인 범위 안 구현 오류이면 `implementing`으로 돌아가 수정·재검증한다. `verification_status: blocked`, `status: verification_blocked`는 원천 접근 불가, 실행 환경·외부 의존성 실패, 원천 상충처럼 코드 수정만으로 다음 검증을 실행할 수 없을 때만 사용한다. source/render 경계나 기존 Golden identity가 잘못됐지만 올바른 원천·환경을 즉시 다시 만들 수 있다면 차단 상태로 종료하지 않고 해당 증거를 다시 생성한다.
- 검증 뒤 파일이 바뀌면 영향 그래프에서 그 파일이 연결된 render root·fixture·Golden의 증거만 무효화한다. 무관한 문서·timestamp·다른 화면 변경 때문에 완료된 Snapshot을 반복하지 않는다.
- Snapshot 인프라 도입이 승인 범위를 벗어나면 임의로 추가하지 않고 재승인한다.
