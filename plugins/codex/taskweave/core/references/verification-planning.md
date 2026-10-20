# 필요한 검증과 실행 준비

검증 비용과 실행 자원은 구현이 끝난 뒤 처음 발견하지 않고 계획 단계에서 분류한다.

현재 승인 메모의 코드·검증안, 또는 기존 Workplan의 code-plan/test-plan에서 실제 API 제약·가장 가까운 테스트·생성 리소스 접근자·존재하는 실행 대상과 명령을 확인해 인계한다. 설정이나 선언으로 확인 가능한 사항 때문에 전체 빌드를 미리 실행하지 않는다. 불확실하면 해당 최소 범위만 조사하고 미확인을 `ready`로 숨기지 않는다. 기록 위치는 [Workplan 작성과 실행](workplan-layout.md)을 따른다. 대화 코드 승인 경로는 같은 선택 원칙을 대화에 적용하며 새 Workplan을 만들지 않는다.

첫 명령 전에 가장 가까운 기존 테스트에서 실제 test identifier·fixture·assertion·동시성 격리와 framework 관용구를 확인한다. production/test 대상의 manifest 직접 의존성·import·link 경계, 직접 test가 compile 증거도 제공하는지, 현재 실행 설정 존재 여부를 대조한다. 프로젝트 재생성은 manifest·resource·실행 대상·dependency graph 변경 또는 필수 설정 부재일 때만 계획한다. 결과는 긴 재조사가 아니라 선택한 명령, 필요한 setup과 예외 사유에 반영한다.

## 플랫폼 지침 선택

- Apple 프로젝트만 [Apple 검증](verification-apple.md)을 읽는다.
- Android 프로젝트만 [Android 검증](verification-android.md)을 읽는다.
- 혼합 저장소는 실제 변경된 플랫폼·모듈만 선택한다. 플랫폼을 추측하거나 양쪽 전체 빌드를 기본 실행하지 않는다.
- 원천 대조·시각 변경이 있으면 플랫폼과 별개로 [UI 검증](ui-verification.md)을 더 읽는다. Swift Testing, Xcode, Android SDK를 다른 플랫폼의 필수 조건으로 전파하지 않는다.

로직 변경에는 영향 단위 테스트가 기본이다. 플랫폼 API·저장소 경계는 필요한 통합 테스트, 사용자 조작은 동작 테스트, 시각 계약은 영향 상태의 원천·렌더 비교로 연결한다. 에뮬레이터·기기·스크린샷·전체 앱 빌드는 실패 위험이 해당 경계에 있을 때만 선택한다. 테스트가 같은 코드를 컴파일하면 별도 빌드를 중복 실행하지 않는다. 선택한 목적·대상·식별자·정확한 예상 명령과 제외 범위를 실행 전에 사용자에게 설명한다.

## 최소 검증 설계

새 `approval-memo-v1` feature·bug 메모는 main의 `## 검증 계획` 표에 검증할 동작과 실패 조건, 기존/신규 테스트 파일·식별자, 실제 실행 명령, 통과 기준을 한 행씩 쓴다. 실행하지 않을 검증은 `- 제외:`에 이유를 남긴다. 승인 출력은 이 표를 그대로 보여 주며 placeholder가 남으면 승인 준비를 통과하지 못한다. 기존에 승인된 메모와 direct 작업은 기존 최소 검증 기록을 그대로 사용한다.

변경마다 `change` → `failure_risk` → `method` → `pass_criterion`을 짧게 연결한다. 새 메모는 위 검증 표를 사용하고 REQ/CODE/TEST 형식용 문서를 만들지 않는다. 기존 구조화 Workplan은 아래 ID·필드 규칙을 그대로 유지한다. 필요한 검증 종류는 [작업 근거 선택](context-pack.md)의 실제 영향과 제외 이유에서 고르며 새 selector를 만들지 않는다.

direct는 `direct-v1`의 실제 선택 impact에 대해서만 직접 검증한다. 선택하지 않은 impact의 `omitted_by_direct_route`는 normal/high-risk의 구체적 제외 사유를 대체하지 않는다.

- 새 assertion이나 변경된 행동·버그를 검증하는 test는 기존 `TEST-* Direct test` code fence에 의미 있는 assertion을 남긴다.
- 현재 존재하는 test를 그대로 재사용하면 `verification_kind: existing_test`와 정확한 `file`, source에 실제로 있는 `identifier`, `command`를 남기고 `test_code`를 복제하지 않는다. 승인 gate는 지정 Git root 안의 test source와 identifier를 확인하며 이 확인을 실행 성공으로 표시하지 않는다.
- 소스·시각·정적 검토가 적합한 요구는 `verification_kind: static_review`, `review_type: source_review|visual_review|static_analysis`, `independent_expectation`, `scope`, `applicability_reason`을 남긴다. 실행 검증이 적용되지 않을 때만 `executable_not_applicable: "not_applicable: <구체적 이유>"`를 추가한다. 가짜 unit test code나 가상 명령을 만들지 않으며, 신규·변경 행동의 실행 가능한 검증을 대체하지 않는다.
- 기존 inline `TEST-*`는 migration 없이 읽기 호환을 유지한다. 새 양식을 쓰는 항목만 위 최소 필드를 적용한다.

UI·Figma·Snapshot은 이 최소 기록으로 원천 적합성을 증명하지 않는다. 선택된 visual impact는 기존 `ui-verification-gate`의 inventory·receipt·artifact 검증을 그대로 통과해야 한다.

## Taskweave에서 검증을 진행하는 방법

스킬을 읽은 AI가 실제 변경과 실패 위험에 맞는 테스트를 선택하고, 사용자에게 필요한 검토 범위를 설명한 뒤 호스트의 기존 실행 도구로 수행한다. 이미 승인한 검증 범위를 MCP에 다시 승인받지 않는다. Taskweave의 기본 MCP는 자료 조회·현재 작업 찾기·안전한 기록 저장만 제공하며 테스트 실행·승인 심사 도구를 요구하지 않는다.

검토할 동작·명령·기대 결과가 명확하면 직접 검증을 진행한다. 표·heading·식별자·packet의 형식 누락은 보완 메모로 남기고 끝에 정리하며 구현이나 테스트의 선행 조건으로 만들지 않는다. 실제 실행 환경·필요 권한·독립 원천이 없으면 해당 확인의 한계를 설명하고, 실패·미실행을 성공으로 기록하지 않는다. UI는 실제 원천과 같은 상태·경계의 렌더를 대조하며 현재 구현을 독립 기준으로 삼지 않는다.

이 문서의 아래 구조화 자료·기존 CLI 검사는 과거 기록을 해석하거나 사용자가 그 도구를 명시 선택할 때만 참고한다. 새 Taskweave 경로를 위해 구형 양식·별도 검증 승인을 생성하지 않는다.

## 이전 플러그인의 검증 연결 — 기존 기록 해석용

`verification_context`는 신뢰 등록한 프로젝트의 실제 실행 대상을 읽고 플랫폼 지침 경로를 반환한다. `verification_select`는 저장된 context와 소스에서 확인한 테스트 식별자로 최소 항목을 고정한다. `verification_approve`는 사용자 승인 출처와 선택한 항목·설정 digest를 별도 기록한다. 선택만으로 실행을 승인한 것으로 간주하지 않는다.

선택에는 확인한 source/test/config/dependency·필요한 resource의 정확한 상대 파일 목록 `inputPaths`를 함께 고정한다. 실행·보고는 이 목록과 발견한 플랫폼 설정만 hash하며 저장소 전체 파일·무관한 중첩 앱을 순회하지 않는다. 입력 범위의 완전성은 호출자가 영향 경계에 맞춰 확인한다. 목록이 없으면 전수 탐색으로 대신하지 않고 필요한 파일을 요청한다. 실행 중 또는 뒤에 이 입력이 바뀌면 이전 결과를 현재 통과 증거로 재사용하지 않는다.

`verification_run`은 승인 기록 ID와 그 안의 check ID만 받고 임의 shell·명령·Gradle task·추가 인자를 받지 않는다. 설정이 바뀌면 재선택한다. 실행 기록은 관리 데이터에 보관하며 제품 저장소에 보고서를 생성하지 않는다. 기존 Workplan이 있으면 그 결과에 연결하고 대화 코드 승인 경로에는 새 Workplan을 요구하지 않는다.

## 실행 profile

- `normal`: 단일 target의 직접 테스트처럼 기존 workspace와 기본 runner로 바로 실행할 수 있다.
- `long_running`: 전체 workspace build, 프로젝트 재생성, 여러 scheme·locale·Snapshot 묶음, UI test, 다중 저장소 또는 공유 simulator·DerivedData·artifact를 사용한다.

고정된 분 수가 아니라 준비 비용과 공유 자원 충돌 가능성으로 판정한다. 새 메모는 main의 검증 계획에 필요한 setup·캐시·공유 자원·실행 순서·재시도 범위를 기록하며 긴 코드처럼 판단에 꼭 필요한 추가 자료만 연결한다. 승인 전에 실제 실행 가능성과 빠진 자원을 확인하되, 승인된 구현을 시작하려고 구형 문서 세트를 새로 만들지 않는다.

기존 `verification-plan validate` 계약을 사용하는 Workplan은 `verification_execution_profile`, `verification_preflight_status`와 `detail_documents.test_plan`을 유지한다. 현재 이 별도 validator는 새 메모 전용 생략 분기를 지원하지 않으므로, 기존 `long_running` 계약을 명시적으로 사용하는 경우에는 아래 packet이 필요하다. 문서만 고쳐 그 검사가 생략됐다고 보고하지 않는다.

## 기존 계약의 장시간 검증 자료

기존 Workplan의 `detail_documents.test_plan`이 가리키는 파일(통상 `Details/test-plan.md`)에는 다음 제목과 실제 값을 기록한다. 아래 제목은 현재 parser가 정확히 검사하는 식별자이므로 번역하지 않는다. 그 아래 설명과 실행 해설은 한글로 작성한다.

- `## Direct Tests`: 가장 가까운 test identifier와 정확한 명령
- `## Setup and Cache`: workspace 존재 여부, 프로젝트 재생성 조건, DerivedData·기존 build 재사용
- `## Resources and Ordering`: simulator UDID, scheme·locale·Snapshot ID, artifact 경로와 직렬·병렬 순서
- `## Retry and Stop`: 실패 분류, 재실행 범위, 환경 복구 1회와 중단 조건

긴 suite를 관성적으로 계획하지 않는다. 직접 테스트가 compile 증거를 제공하면 별도 build를 제거하고, 실패하거나 미실행된 영향 범위만 다시 실행한다.

## 실행 게이트

새 메모의 승인 검사는 `workplan-memo validate --phase approval`을 사용한다. 별도 `verification-plan validate <Workplan>`은 그 필드·packet 계약을 사용한 기존 Workplan에만 적용한다. apply 단계는 승인 때의 확인 결과를 재사용하고 plan·workspace·명령·자원이 바뀐 경우에만 영향받은 준비를 다시 확인한다.

준비 부족은 승인된 제품 코드 구현을 막지 않으며 첫 검증 전에 보완한다. 기존 `long_running` packet 또는 실제 자원·순서가 끝내 준비되지 않으면 구현 결과를 버리지 않고 검증 완료만 차단한다. 제품 범위·검증 완료 조건이 달라질 때만 재승인하며 계획 형식 보수로 자동 재승인하지 않는다.

실행 결과 인계는 [검증 근거](verification-evidence.md)의 `verification-plan reusable` 절차를 사용한다. 결과 재사용 검사는 테스트를 실행하지 않으며, 실제 명령의 성공과 원천 적합성은 각각 별도 근거를 유지한다.
