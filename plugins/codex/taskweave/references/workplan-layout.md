# Workplan 작성과 실행

이 문서는 코드 Workplan의 기록 위치·내용을 소유한다. 진행과 권한은 [실행 계약](execution-contract.md), MCP 사용은 [플러그인 실행 연결](plugin-runtime.md)을 따른다. 스킬을 읽은 AI가 호스트 도구로 기록·수정·직접 검증한다. 이전 `workplan-memo`·MCP 승인/시작/검증 명령이나 문서 형식 검사의 성공을 새 Taskweave 경로의 작업 허가로 요구하지 않는다.

## 새 코드 Workplan: `approval-memo-v1`

정식 Workplan이 필요한 새 코드 작업만 확인된 `<workplan_root>` 아래에 기록한다. `$taskweave:code-change`는 대화 변경안·사용자 승인이 기본이며 사용자 요청·회사/저장소 의무·인계 필요가 있을 때만 짧은 문서 하나를 사용한다. 문서 없는 작업에 bundle·Completion·승인 hash·기록 위치 확인을 붙이지 않는다. 일반 글쓰기에 Workplan을 기본 요구하지 않는다.

```text
<workplan_root>/
└── <ID>/
    ├── <ID>.md
    ├── Completion.md         # 구현 뒤 실제 변경·검증 기록
    └── Details/              # 긴 코드 설명이 정말 필요할 때만
        └── plan-code.md
```

새 메모에는 `workplan_schema: approval-memo-v1`과 변경 이유·핵심 현재/제안 코드·파일/심볼·유지/제외 범위·직접 검증·계획 버전을 담는다. 검증 계획은 영향 동작별 테스트 파일·식별자·명령·실패/통과 기준과 필요한 제외 이유를 적는다. 고정 제목·필드 형식을 채우는 것보다 사용자가 실제 변경을 이해할 설명을 우선한다.

여러 데이터·상태·호출 경로가 바뀌면 행동별 핵심 구현 구상을 실제 언어 코드로 설명한다. 긴 코드만 선택적 `Details/plan-code.md`로 분리하고 main과 승인 응답에는 판단에 필요한 대표 코드·이유·검증을 남긴다. 비어 있는 Detail·REQ/CODE/TEST graph·knowledge 문서·heading/hash용 보조 문서를 만들지 않는다.

## 파일 이름과 위치

새 ID·폴더·본문 파일은 `YYYYMMDD-짧은-영문-작업명`으로 맞춘다. Jira가 연결됐으면 [티켓 선택 규칙](ticket-lifecycle.md#새-작업-기록)으로 정한 정확한 기준 key를 사용해 ID·폴더·파일명은 `YYYYMMDD-<기준-key>-짧은-영문-작업명`, 제목은 `<기준-key> · 작업 설명`으로 쓰고 `jira_key`에도 같은 key를 기록한다. 사용자가 지정한 기존 key의 접두어를 기본 생성 프로젝트의 접두어로 바꾸지 않는다. 번호를 추측하거나 문서 이름을 맞추려고 새 티켓을 만들지 않는다.

이름은 생성 시 정하는 관례다. 날짜·작업명 형식이나 메타데이터 부족은 끝에 보완하며 구현 허가 검사로 삼지 않는다. 같은 이름이 있으면 덮어쓰지 않는다. 기존 ID·승인·링크는 변경하지 않고 나중에 티켓이 연결돼도 문서를 자동 이동하지 않는다.

개인은 확인된 프로젝트별 관리 위치, 회사는 회사 adapter의 `Workplans/<project-id>`를 사용한다. 제품 저장소·설치 캐시·임의 fallback에 AI 기록을 만들지 않는다. 알려진 위치가 없으면 필요한 위치만 확인하고 전체 프로젝트 등록·과거 이력 검사를 강제하지 않는다.

## 계획 제시와 승인 기록

AI가 변경 컨셉·대표 현재/제안 코드·범위·직접 검증을 먼저 보여 주고 그 안의 사용자 승인을 기다린다. 작은 작업은 대화로 충분하고 Workplan이 필요한 작업만 계획 버전을 기록한다. 최초 구현 요청·기준 합의·plan/apply 호출을 승인으로 쓰지 않는다. 이미 제시한 동일 안의 실행·재시도에는 승인을 반복하지 않는다.

실제 사용자가 말한 승인 내용과 해당 계획·범위를 현재 기록에 한 번 남긴다. 같은 승인을 중복 stamp하거나 저장 때문에 다시 질문하지 않는다. 제목·설명·필드의 부족은 보완 메모로 남기고 끝에 정리한다. AI가 스스로 승인 출처를 만들지 않으며 중요한 범위 변경에는 해당 추가 계획만 재승인받는다.

## 구현 뒤 결과와 피드백

실제 핵심 변경 전후 코드·이유·계획 편차·명령·결과·미실행 범위를 `Completion.md`에 기록한다. 구현 전에 결과 파일을 만들지 않는다. 기존 결과의 구조화된 `approval-memo-result-v1`·검증 식별 정보는 보존하되 새 문서 schema 검사 통과를 실제 테스트 성공으로 대신하지 않는다.

UI 근거는 필요한 경우 bundle의 `Artifacts/`에 실제 source·candidate·비교 결과와 함께 저장한다. `none | regression | conformance | full`의 영향 View·state에 맞는 제품 검증은 유지한다. packet·hash·manifest 영수증은 기존 도구와의 호환 근거일 뿐 새 Taskweave의 편집·검증 시작·성공 보고를 위한 문서 심사 조건이 아니다. 실제 테스트 건수·원천 결과는 실행에서 확인하며 만들어 쓰지 않는다.

현재 승인 범위 안 피드백은 같은 Workplan·현재 구현에서 이어가고 직접 영향만 재검토한다. 범위가 넓어지면 현재 구현을 보존하고 추가 이유·현재/제안 코드·검증을 같은 기록에 보강해 재승인받는다. 최초 코드 상태 복구·기준선 재고정·최초 승인 반복은 하지 않는다. 세부 분류는 [피드백 절차](acceptance-feedback-loop.md)를 따른다.

## 저장 안전과 작업 상태

`record_save`를 쓸 때는 고유 요청 ID와 읽었던 기존 내용의 지문으로 원자적 저장·멱등 재시도·동시 변경 충돌 감지를 맡긴다. 지문은 구현 승인 조건이 아니다. 충돌·권한 거절을 무시해 호스트 파일 도구로 강제 덮어쓰지 않는다. 연결·저장 실패는 미저장 위치를 알리고 이미 확보한 자료로 가능한 작업을 계속한다.

```text
draft → awaiting_approval → approved → implementing → verifying
      → awaiting_completion → completed
```

이 상태는 진행 사실의 기록이지 MCP가 발급하는 실행 허가가 아니다. 중요한 범위 변경은 `needs_reapproval`, 필수 검증의 외부 차단은 `verification_blocked`로 구분한다. 관련 테스트 실패·원천 불일치는 실제 제품을 수정·재검토하며 형식 경고로 바꾸지 않는다. 제목·필드 보완만으로 차단 상태나 재승인을 만들지 않는다.

구현·직접 검증 성공은 `awaiting_completion`까지다. Workplan/Jira 종료·`completed_at`·회사 지식 게시에는 사용자 명시 완료 요청이 필요하고 `$taskweave:complete-work`가 처리한다. Git 게시 권한은 별도다.

## 기존 Workplan 보존

`stable-bundle-v1`, `compact-v1`, `split-v1`, `scope-v2`, `scope-v3`와 기존 approval memo의 schema·revision·Details·승인 hash·gate 실행 결과를 그대로 보존한다. 자동 migration·새 메모 재작성·기존 Detail 제거·지식 문서 추가·같은 승인 반복은 하지 않는다.

기존 기록을 이어간다는 이유로 과거 문서 gate를 새 Taskweave 진행에 강제하지 않는다. 명시적으로 요청된 호환 도구 실행만 해당 기록에 한정하며 새 작업의 CLI fallback으로 삼지 않는다. 회사 후처리·실제 제품 검증·외부 권한 경계는 계속 유지한다.
