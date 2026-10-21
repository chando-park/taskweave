---
name: feature-plan
description: 복잡한 코드 기능 변경의 원천·현재/제안 코드·직접 검증을 Workplan에 정리하고 제시한 계획 버전의 승인을 기다린다. 간단한 수정은 code-change로 보내며 구현하지 않는다.
---

# 기능 변경 계획

경로·권한은 [실행 계약](../../references/execution-contract.md)과 [위험 분류](../../references/risk-routing.md)를 따른다. 보육일지·요약·대본 등 글쓰기는 [글쓰기 작업](../../references/writing-work.md)으로 연결하며 코드 기능 계획으로 만들지 않는다. 간단하고 명확한 저위험 코드 수정은 /taskweave:code-change, 현재 Workplan 구현 피드백은 /taskweave:apply-workplan-feedback으로 이어간다. 복잡한 변경·중요한 선택·넓은 영향·고위험 또는 회사/저장소 의무 조건이면 [Workplan 양식](../../references/workplan-layout.md)을 사용한다. 단순한 방향 질문은 읽기 전용으로 답하며 구현하지 않는다.

code-change로 연결해도 승인을 생략하지 않는다. 작은 수정은 대화에 변경 전후 코드·검증 방법을 먼저 보여 주고 승인받으며, 문서는 필요할 때만 사용한다.

## 시작과 조사

1. 현재 프로젝트·지침·알려진 정책에서 repository·기록 위치를 확인한다. 부족할 때만 사용 가능한 resolver로 보완하며 회사 Project Agent가 있으면 코드·티켓보다 먼저 읽는다.
2. 사용자 기획·URL·첨부·직접 연결 원천과 가까운 코드·테스트에서 이유·예상 파일·직접 검증을 좁힌다. semantic 조사 전 [Serena 절차](../../references/serena-code-intelligence.md)를 실행하고 실제 symbol·caller·implementation을 확인한다. 도구가 없으면 추정한 경계를 ready로 판정하지 않는다.
3. 회사 정책이 현재 작업의 티켓을 필수로 요구할 때만 [티켓 절차](../../references/ticket-lifecycle.md)로 생성하거나 정확한 기존 번호를 연결한다. `none`·선택 사항·미확인 정책이면 자동 생성하지 않는다. Workplan 작성 자체를 티켓 생성 근거로 삼지 않으며 과거 티켓·Workplan을 전역 검색하지 않는다.
4. 확인된 관리 위치에 호스트 파일 도구 또는 `record_save`로 새 메모를 한 번 만들고 같은 draft에서 필요한 조사만 이어간다. Taskweave MCP는 조회·현재 작업 찾기·저장만 맡는다.
5. [모델 라우팅](../../references/model-routing.md)의 직접 경로 조건이 모두 확정됐으면 부모가 계획한다. 불확실성·위임 조건이 남으면 model-route --stage planning --model <model> --available-model <실제-후보> ...가 선택한 planning agent를 실제 실행한다. GPT-6 우선·실제 dispatch 증거·부모의 쓰기 소유권을 유지한다.

## 필요한 문서 선택

- UI 요구: /taskweave:plan-ui-with-design-system을 같은 메모에 적용한다.
- 모든 승인안 작성: [구현 인계의 공통 설명 작성 원칙](../../references/implementation-handoff.md#공통-설명-작성-원칙)을 읽고 본문과 상세 코드 설명에 적용한다. 복잡한 코드 인계·부족한 원천·제품 결정은 같은 문서의 승인 코드·질문·재개 기준을 따른다. 질문 중에는 같은 draft를 보존한다.
- 비자명한 제약을 주석으로 남길 계획: [주석 계약](../../references/code-comment-contract.md).
- 작성 형식·준비 판단: [계획 예시](references/feature-plan-template.md)와 필요할 때 [준비 기준](references/readiness-checklist.md).

## 승인안

승인 요청 전에 위 공통 원칙으로 본문과 연결된 상세 코드 설명을 함께 확인한다. 사용자가 새 기능의 현재/변경 후 동작, 요청·실행 주체, 코드 흐름과 검증 방법을 이해할 수 있게 원문을 다듬는다. 문서 검사 성공만으로 설명이 충분하다고 판단하지 않는다.

이유, 핵심 현재/제안 코드, 파일·심볼·caller·assembly, 유지·제외 범위, 직접 검증과 남은 제품 결정을 기록한다. 실제 API·삽입 지점·소비 코드·테스트를 확인하고 원문에 없는 동작을 발명하지 않는다. 여러 경로가 바뀌면 선택적 `## 구현 구상`에서 데이터·상태·화면 연결과 제거할 호출을 실제 언어 코드로 보여 준다. 작은 변경은 before/after 한 쌍이면 충분하다.

새 메모의 `## 검증 계획`에 영향 동작별 테스트 파일·식별자·명령·실패/통과 기준을 적고, 제외한 Snapshot·전체 빌드는 이유를 남긴다. 원천·API·코드·검증 경계 또는 외부 계약·보안·의료 데이터 결정이 미확정이면 질문하고 승인 준비를 멈춘다. source graph·필수 REQ/CODE/TEST graph·knowledge 문서·형식용 Detail을 만들지 않는다.

AI가 한글 컨셉·현재/제안 코드·검증 계획·계획 버전을 사용자에게 직접 보여 준다. 그 응답은 승인 요청으로 끝내고 사용자가 해당 계획 버전을 명시 승인할 때까지 기다린다. 최초 구현 요청·기준 합의·feature-apply 동시 호출을 승인으로 해석하거나 스스로 승인 출처를 만들지 않는다. 승인 뒤 /taskweave:feature-apply가 같은 메모에서 이어간다. 계획 중 제품 코드·테스트·Product Memory·Jira 구현 상태를 바꾸지 않는다.

문서 제목·필드·설명 형식 부족은 경고하고 끝에 보완한다. 기존 MCP/CLI의 prepare·validate·approve·apply 성공을 새 Taskweave 진행 조건으로 요구하지 않는다. 실제 원문·제품 결정 부족은 그 정보만 확인하며 형식 문제와 구분한다. 기존 Workplan의 schema·revision·gate 실행 이력은 보존하고 자동 변환·같은 승인 반복은 하지 않는다.
