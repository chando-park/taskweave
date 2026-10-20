# Verification Evidence

이 문서는 모든 변경의 공통 완료 판정만 소유한다. 분야별 세부 절차는 작업에 해당할 때만 읽는다.

- UI·Figma·Snapshot: [UI Verification](ui-verification.md)
- 사용자 노출 문자열: [Localization Contract](localization-contract.md)
- Apple 실행·결과 해석: [Apple Verification](verification-apple.md)
- Android 실행·결과 해석: [Android Verification](verification-android.md)
- Workplan 시각과 상태 메타데이터: [Workplan Metadata](workplan-metadata.md)
- 장시간 검증의 사전 준비: [Verification Planning](verification-planning.md)

## 공통 검토와 보고

모든 작업은 실제 결과를 원문·요구사항·합의한 기준과 대조하고 무엇을 확인했는지, 무엇을 확인하지 못했는지 쉬운 한글로 설명한다. 결과물 존재나 도구 연결 성공은 검토 통과를 뜻하지 않는다. 사실·기존 주장·추론을 구분하며 실행하지 않은 검토를 수행했다고 보고하지 않는다.

요약은 핵심 누락·표/수치·조건·분량을 원문과, 대본은 원래 의도·청중·말투·길이를 합의 기준과 비교한다. 비코드에서는 실제 사실·의미·표현·형식 검토를 보고하고 앱 테스트·코드 커버리지·Git diff·플랫폼 결과 필드를 강제하지 않는다. 코드/실행 설정 변경에는 아래 테스트·커버리지 규칙을 적용하며 테스트가 해당하지 않는 문서/설정 부분은 직접 확인 내용과 이유만 기록할 수 있다.

검토의 자세함과 기록은 위험·산출물에 비례한다. code-change는 기존 짧은 작업 문서 하나에 결과를 갱신하고 사용자에게 요약한다. 그 밖의 Workplan 없는 일반 대화 작업은 대화로 충분하며, 보고를 위해 정식 Workplan·별도 결과 문서를 만들지 않는다. 외부 계약의 사실 확인이 필요했으나 자료가 없다면 그 한계를 남긴다.

Taskweave에서는 실제 수정·검토를 호스트 도구로 수행하고 MCP에는 자료 조회·현재 작업 찾기·기록 저장만 요청한다. 아래 기존 packet·schema·receipt·CLI 검사 형식은 새 작업의 실행·승인·보고 선행 조건이 아니다. 실제 결과·출처·수행한 확인과 미확인을 기록하면 진행하며 형식 보완은 끝에 묶는다. 실제 테스트 실패·UI 원천 불일치·필요 권한 부재는 단순 형식 경고와 다르므로 숨기지 않는다. 회사·기관의 명시적 의무 검토와 사용자 최종 완료 권한은 유지한다.

## 코드 변경의 완료 증거

- 변경한 파일과 핵심 동작
- 실행한 정확한 명령
- 테스트 실행 건수와 성공·실패·건너뜀 결과
- 빌드·lint·문서 검사 결과
- `git diff --check`와 범위 밖 변경 검토
- 실행하지 못한 검증, 이유, 대체 근거와 남은 위험

컴파일 성공은 테스트 통과가 아니다. 테스트 0건이나 실행 전 종료는 `passed`로 기록하지 않는다. 위험에 비례해 가장 직접적인 회귀 테스트부터 실행하고, 외부 계약이나 넓은 영향일 때만 범위를 확대한다. 하나의 직접 test가 영향 target을 실제로 컴파일하고 실행했다면 compile과 test의 실행 증거로 함께 재사용할 수 있으며, 같은 configuration의 별도 build를 관성적으로 반복하지 않는다. 프로젝트 생성도 manifest·resource·scheme·dependency graph 변경 또는 workspace 부재처럼 실행에 필요한 경우에만 수행한다.

검증 결과에는 사용한 adapter, 플랫폼·모듈/target·variant/destination, 실제 실행 식별자·건수와 결과 위치를 남긴다. 도구 연결 성공, 컴파일, 테스트, Preview, Snapshot과 원천 적합성은 각각 분리하며 하나의 성공을 다른 항목의 통과로 확대하지 않는다.

exit code 0만으로 통과시키지 않는다. 이번 실행의 실제 JUnit XML·xcresult 또는 호스트 도구의 원본 결과를 읽고 실행·통과·실패·skip을 분리한다. `NO-SOURCE`, discovery 0건, 전부 skip은 테스트 실행 증거가 아니다. `UP-TO-DATE`·`FROM-CACHE`는 새 실행과 구분하며 입력·설정·도구·범위가 같은 기존 증거를 확인한 경우에만 재사용으로 보고한다. 현재 플러그인의 cache 결과는 자동 재사용 통과시키지 않는다. 오래된 결과 파일, 승인 대상과 다른 식별자·기기의 결과는 합산하지 않는다. device 없음·설정 오류·timeout은 해당 검증의 차단/실패로 남긴다.

커버리지는 가능하면 기존 테스트 실행 때 기존 도구·설정으로 함께 측정한다. 수집 실패·미지원·과도한 비용이면 가능한 결과와 이유를 기록하고 진행한다. 커버리지 보고만을 위해 새 도구 설치·별도 전체 테스트·반복 실행을 요구하지 않는다. 대상 모듈·variant·코드 범위·제외 항목, line/branch 등 측정 기준과 실측값을 기록하고 분자·분모는 도구가 제공하면 함께 적는다. 변경 코드 커버리지도 기존 결과에서 얻을 수 있을 때 표시하며 부분 범위를 전체 커버리지로 표현하지 않는다. 측정하지 않은 branch를 line으로 대신하지 않고 임의 공통 80% 기준을 요구하지 않는다. 미측정은 0%가 아니라 `미측정 — 이유`이며, 구조화 결과를 이미 사용하는 경우 `measured: false`로 남긴다.

## 테스트·커버리지 기록

코드 테스트가 해당하는 작업의 완료 보고에 다음 내용을 쉬운 한글로 기록한다. 표나 짧은 목록 중 읽기 쉬운 방식을 사용하며 고정 schema·필수 필드 검사·별도 artifact를 추가하지 않는다. 비코드 요약·대본에는 이 목록이나 `커버리지 미측정` 행을 억지로 요구하지 않고 위 공통 검토 결과로 보고한다.

- 실제 실행한 테스트 파일·케이스 식별자, 각 테스트가 확인한 동작과 통과·실패·건너뜀 결과. 실행하지 못한 항목은 미실행과 이유를 적는다.
- 전체 실행 수와 통과·실패·건너뜀 수. 원본 결과가 제공하지 않는 식별자나 건수는 추정하지 않고 확인 가능한 범위와 미확인 이유를 적는다. 항목이 많으면 Workplan에 상세를 두고 응답에는 주요 결과와 집계를 보여 준다.
- 커버리지의 측정 범위·기준·실측값 또는 `미측정 — 이유`. 테스트 통과율을 코드 커버리지로 표현하지 않는다.
- 실행 명령·대상과 기존 로그·결과 위치, 미검증 범위와 남은 위험. 코드 테스트가 해당하지 않는 문서·설정 작업은 `테스트 미실행 — 문서·설정 변경` 등 실제 이유와 직접 확인한 내용을 기록한다.

Workplan이 있으면 해당 Workplan 문서의 기존 검증 영역에 테스트 결과와 커버리지를 통합한다. 테스트 파일·케이스 식별자와 실행 대상·설정이 같으면 기존 결과 행을 최신 실행 결과·시각·근거 링크로 덮어쓰며 같은 테스트의 행을 누적하지 않는다. 서로 다른 실행 대상·설정은 구분하고, 재실행하지 않은 테스트의 결과는 임의로 갱신하지 않는다. 검증 계획·승인 기록·기존 원본 로그는 보존하며 별도 테스트 보고서 문서를 만들거나 Completion에 상세 표를 중복 복제하지 않는다. Completion이 필요한 경로에서는 요약과 Workplan의 검증 영역 링크로 연결한다. code-change는 기존 짧은 작업 문서에 같은 원칙으로 갱신하고, 그 밖의 Workplan 없는 일반 대화 작업은 대화에 기록한다. 이 보고만을 위해 정식 Workplan을 만들지 않는다.

이 기록 절차는 가능한 사실과 한계를 남기면 진행한다. 보고 양식·항목 누락·커버리지 수집 오류만으로 새 오류·엄격한 문서 검증·승인 단계·완료 차단 조건을 만들지 않는다. 기존 결과에서 확인할 수 없는 항목은 미확인 또는 미측정으로 적으며 기록 형식을 맞추려고 테스트를 다시 실행하지 않는다. 실제 테스트 실패와 기존 필수 동작 검증의 미실행은 그대로 보고하며, 보고 작성이 끝났다는 이유로 테스트 통과로 바꾸지 않는다.

사용자 노출 문구가 바뀌면 localization source·locale behavior·literal audit을 별도 증거로 기록한다. 빌드·테스트·Snapshot·Figma 문구 일치는 문자열이 현지화 리소스에서 왔음을 증명하지 않는다.

계획의 검증 항목은 [Verification Planning](verification-planning.md)의 최소 `change → failure_risk → method → pass_criterion`으로 설계한다. 존재하는 test source를 확인한 것은 테스트를 실행한 것이 아니며, 정적·소스·시각 검토는 새·변경 행동의 실행 가능한 assertion을 자동으로 대체하지 못한다. UI 원천 적합성은 정확한 원천과 대상 렌더의 실제 대조로 확인하며 테스트 통과나 문서 영수증의 존재로 대신하지 않는다. 기존 receipt·artifact 형식은 원래 기록의 해석에 사용할 수 있지만 새 필수 문서 검사로 만들지 않는다.

## 실행 전 점검

[Verification Planning](verification-planning.md)이 실행 준비의 단일 원본이다. 필요한 대상·명령·공유 자원만 확인하고 같은 준비를 반복하지 않는다. Taskweave는 profile·packet이나 `verification-plan validate`의 성공을 요구하지 않는다. 이미 해당 도구로 관리하던 증거를 조회할 때도 실제 입력·환경이 달라진 영향만 확인한다.

## 실행 순서와 복구 한도

1. 가장 직접적인 unit·integration·회귀 test를 먼저 실행한다.
2. UI 변경이면 직접 동작 test 뒤 영향받은 Snapshot ID만 실행한다. 넓은 suite는 직접 범위가 통과하고 교차 영향 근거가 있을 때만 실행한다.
3. 기존 프로젝트 출력·캐시 재사용을 기본으로 한다. clean build나 새 출력 디렉터리는 캐시 손상을 가리키는 근거가 있거나 동일한 일반 실행이 비결정적으로 실패한 뒤의 복구 수단이다.
4. 실패를 assertion·compile·link·Snapshot mismatch·runner·simulator·cache로 먼저 분류한다. 코드·기대값 실패는 수정 뒤 직접 범위만 다시 실행하고, runner·simulator·cache 실패는 동일 원인을 확인하기 위한 안전한 복구를 한 번만 시도한다.
5. 같은 원인의 환경 실패가 복구 뒤 반복되면 다른 명령·runtime·전체 suite를 연쇄 실행하지 않고 `verification_blocked`로 기록한다. 실패하지 않았거나 이미 완료된 영향 범위는 다시 실행하지 않는다.

동시에 실행하는 검증이 같은 기기 ID, 프로젝트 출력·캐시 또는 결과·artifact 디렉터리 중 하나라도 공유하면 직렬 실행한다. 병렬 실행은 이 자원이 모두 분리되고 프로젝트 도구가 동시 실행을 지원할 때만 허용한다. 기기 초기화·데이터 삭제·새 기기 생성·의존성 업그레이드는 일반 테스트 실행 승인에 포함하지 않는다.

사용자 보고는 “무엇을 확인했는지 → 어떤 테스트를 실제 실행했는지 → 몇 건이 통과·실패·skip됐는지 → 무엇은 확인하지 않았는지” 순서의 쉬운 한글로 작성한다. 원본 로그와 결과는 필요한 범위만 연결하고 비밀·의료·사용자 데이터는 복제하지 않는다. 원본 결과를 관리 데이터에 저장하기 전 민감정보 포함 여부를 확인하며, 민감정보가 섞인 원본을 그대로 전달하지 않는다. 자동 테스트 성공과 사용자의 최종 완료 결정도 분리한다.

결과 보고에서는 구현, 직접 동작 검증, 시각 검증, Jira·Workplan 등 행정 처리, 환경 실패 재시도 시간을 가능하면 구분한다. 전체 경과 시간을 코드 구현 시간으로 뭉뚱그리지 않는다.

## 요구사항-증거 행렬

외부 문서·Figma·API·플랫폼 분기처럼 코드 밖의 계약이 기대 동작을 정하는 작업은 다음 행렬을 남긴다.

| 요구사항 ID | 원천·revision·state | 입력·경계 | 독립 기대값 | 영향 심볼 | Compile | Behavior | Render·원천 적합성 | 실행 증거·결과 | 비증명 범위 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |

- 원천의 실제 조회 범위와 역할을 구분하고 일부 상태를 전체 계약으로 일반화하지 않는다.
- 구현 상수나 같은 계산을 복제한 테스트는 `내부 일관성`만 증명하며 `원천 적합성` 증거가 아니다.
- 연속 수치·임계값은 최소한 `경계 직전·경계·경계 직후` fixture와 기대값을 기록한다.
- compile, behavior, render와 원천 대조는 서로 다른 증거다. 하나를 다른 성공으로 기록하지 않는다.
- 필수 실행 증거가 없으면 `verification_status: blocked`, `status: verification_blocked`로 기록한다.
- 승인된 요구사항 안의 구현 오류는 같은 작업에서 수정한다. 원천 해석·요구사항·Public API가 달라지면 재승인하고, 독립된 기존 결함만 별도 Bug로 분리한다.

## 검증 유효성

- 결과는 마지막 코드·테스트 편집 이후 실행된 경우에만 유효하다.
- 검증 뒤 관련 파일이 바뀌면 그 파일의 영향 그래프에 연결된 compile·behavior·render의 이전 결과를 폐기하고 직접 검증을 다시 실행한다. 무관한 파일 변경은 이미 완료된 검증을 무효화하지 않는다.
- 완료 직전에 tracked diff와 관련 untracked 파일을 다시 확인한다.
- 문서 변경이 완료 조건이나 검증 해석을 바꿨다면 재검증 또는 재승인한다. 단순 결과·timestamp 기록은 코드 검증을 무효화하지 않는다.
- Workplan에는 실제 검증 시각을 `verified_at`으로 남긴다.

### 구현자 → 부모 결과 재사용

구현자는 실제 명령·대상·결과·마지막 관련 변경 시점을 전달하고 부모는 같은 입력의 결과를 관성적으로 재실행하지 않는다. 아래 `verification-plan`은 기존 구조화 증거를 선택적으로 재사용하는 방법이며 새 Taskweave 작업의 필수 절차가 아니다. 이미 증거가 있으면 prepare/capture부터 반복하지 않는다.

```text
verification-plan prepare --repository <Git-root> --prepared <중앙 Artifacts/prepared.json> --kind test --command '<실제 검증 명령>' --input source:<경로> --input tests:<경로> --input config:<경로>
실제 검증 명령 실행 → 실제 로그에서 결과 JSON 생성
verification-plan capture --repository <Git-root> --prepared <prepared.json> --evidence <evidence.json> --command '<동일 명령>' --result-artifact <result.json>
verification-plan reusable --repository <Git-root> --evidence <evidence.json> --command '<동일 명령>'
```

Snapshot 결과를 부분 재사용하려면 `prepare`에 각 실제 Snapshot ID를 `--subject-id`로 전달하고 source/tests/config 외에 render 환경을 담은 `--input environment:<경로>`와 실제 사용하는 dependency/resource 입력을 함께 기록한다. 이 scoped v2 evidence는 동일 worktree/Git dir·명령·subject ID·result artifact와 모든 기록 입력의 현재 hash가 같을 때만 HEAD-only 커밋을 허용한다. 입력 범위의 완전성은 호출자가 실제 dependency/resource graph에 맞춰 구성하며 gate가 자동 추론하지 않는다. `--subject-id`나 필수 입력이 없는 기존 v1 evidence는 HEAD가 달라지면 재사용하지 않는다.

- `--input`은 반복 가능하며 `source|tests|resources|dependency|config|environment` 파일을 받는다. 영향 의존 소스·리소스·manifest/lockfile·fixture와 toolchain/OS·locale·환경 설정을 빠뜨리지 않는다. 입력 목록은 자동으로 추론되지 않으므로 구현자와 리뷰어가 영향 범위의 완전성을 확인한다. 입력·환경을 확정하지 못하면 이 경로로 재사용하지 않는다.
- prepare의 `--kind test|compile`은 승인된 검증 목적에 맞게 고정한다. 일반 result JSON은 실제 실행 로그에서 만든 `verification-result-v1`이며 동일한 `kind`, `status: passed`, 정수 `exit_status: 0`을 갖는다. `--subject-id`가 있는 Snapshot result는 동일 ID 전체와 `executed_count`, `failures: 0`, `exit_status: 0`을 가진 `snapshot-result-v1`을 사용한다. 컴파일 결과로 테스트를 대체하거나 실행하지 않은 명령의 성공 요약을 만들지 않는다. 원본 로그·결과 번들은 기존 verification 기록에 연결한다.
- 도구는 명령을 대신 실행하거나 요구사항 충족을 판정하지 않는다. Git worktree·HEAD·입력 hash·명령·결과 파일의 유효성을 확인하는 인계 도구이며, 원본 로그·테스트 의미·Figma 적합성 검토를 대신하지 않는다.
- 실패·미실행, 입력/명령/결과 변경, 다른 checkout이면 재사용하지 않는다. 관련 코드 변경은 해당 직접 테스트를 다시 실행한다. 중앙 Workplan의 설명·시각만 바뀌면 제품 검증을 반복하지 않는다. 증거 파일은 중앙 Artifacts에 두며 제품 저장소에 AI 문서를 추가하지 않는다.

## 코드 변경 근거

코드 조각은 `implementation-explanation-gate extract --repository <Git-root> --path <상대경로> --start-line <N> --end-line <M>`으로 실제 파일에서 읽는다. 변경 전 코드는 `--base-revision <구현 시작 commit>`을 추가한다. 출력은 stdout뿐이며 사용자가 요청한 의미·호출 흐름·유지 계약 설명은 LLM이 작성한다. 최소 완전한 심볼 범위를 선택하고 전체 파일을 복제하지 않는다. 추출 실패는 해당 경로·범위만 보완하며 코드를 설명에 맞춰 변경하지 않는다.

- 공통 [Implementation Handoff](implementation-handoff.md)와 [Code Comment Contract](code-comment-contract.md)를 적용한다.
- 기능은 현재 삽입 지점·핵심 추가 코드·변경 caller와 State/Action/Effect/Delegate·조립 흐름을, 버그는 원인을 보여 주는 변경 전·후 코드와 유지되는 정상 동작을 기록한다.
- 전체 파일이나 대규모 diff를 복제하지 않고 최소한의 완전한 심볼과 Git diff·commit을 연결한다.
- 실행 명령과 로그, render 비교는 Workplan의 검증 문서에 두고 기본 문서에는 판정만 남긴다.
- 완료 리뷰는 `Details/change.md`의 파일·심볼·코드와 실제 tracked diff가 일치하는지 확인한다. 문서에 없는 주요 변경이나 diff에 없는 예시 코드는 완료 전에 바로잡는다.
- 구현자는 실제 변경 코드·흐름·검증 근거를 반환하고 부모는 직접 검증 뒤 최종 보고 전에 설명을 완성한다. `Details/change.md`에 `implementation-explanation-v1` YAML block을 두고 구현 시작 commit인 `base_revision`과 아직 커밋 전이면 `result_revision: WORKTREE`, 커밋 후 재검증이면 결과 commit SHA를 기록한다. 기능은 CODE별 `files`, `primary_file`, `symbol`, `intent`, `callers`, `tests`, `final_code`, `flow`를, 버그는 `before_code`, `after_code`, `preserved_behavior`를 기록한다. YAML의 코드 참조는 같은 문서의 `### CODE-NN 최종 코드` 또는 `변경 전`·`변경 후` code fence를 가리킨다.
- `excluded_files`는 생성 코드처럼 설명에서 제외할 실제 변경 파일과 구체적 사유만 기록한다. 설명 대상과 제외 대상의 합은 실제 변경 소스 파일 집합과 일치해야 한다.
- 최종 보고는 실제 diff와 설명이 맞는지 직접 확인한다. 기존 `implementation-explanation-gate`는 필요할 때만 참고하며 새 Taskweave 작업의 보고 허가 조건이 아니다. 코드 조각·파일 누락은 설명만 보완하고, 형식 때문에 직접 테스트를 막거나 유효한 제품 테스트를 반복하지 않는다. 실제 제품 코드를 고쳤을 때만 영향 검증을 갱신한다.
