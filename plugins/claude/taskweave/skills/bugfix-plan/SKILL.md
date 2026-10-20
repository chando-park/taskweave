---
name: bugfix-plan
description: 복잡한 코드 버그의 증상·원인·현재/제안 코드·회귀 검증을 Workplan에 정리하고 제시한 계획 버전의 승인을 기다린다. 간단한 수정은 code-change로 보내며 구현하지 않는다.
---

# 버그 수정 계획

경로·권한은 [실행 계약](../../references/execution-contract.md)과 [위험 분류](../../references/risk-routing.md)를 따른다. 보육일지·요약·대본 등 글쓰기 수정은 [글쓰기 작업](../../references/writing-work.md)으로 연결하며 코드 버그 계획으로 만들지 않는다. 원인 미확정이면 먼저 읽기 전용으로 진단한다. 간단하고 명확한 저위험 코드 수정이면 /taskweave:code-change, 현재 Workplan의 피드백은 /taskweave:apply-workplan-feedback으로 이어간다. 복잡한 변경·중요한 선택·넓은 영향·고위험 또는 회사/저장소 의무 조건이면 [Workplan 양식](../../references/workplan-layout.md)을 사용한다.

## 시작과 원인 조사

1. 현재 프로젝트·지침·알려진 정책에서 대상·새 메모 위치를 확인한다. 부족할 때만 사용 가능한 resolver로 보완하며 회사 Project Agent가 있으면 먼저 읽는다.
2. 증상·기대 동작·재현 입력·직접 원천과 예상 파일·회귀 검증을 좁힌다. symbol·caller·implementation 조사 전 [Serena 절차](../../references/serena-code-intelligence.md)를 실행한다. 도구가 없으면 광범위한 텍스트 검색으로 원인을 확정하지 않는다.
3. 회사 정책이 현재 작업의 티켓을 필수로 요구할 때만 [티켓 절차](../../references/ticket-lifecycle.md)로 생성하거나 정확한 기존 번호를 연결한다. `none`·선택 사항·미확인 정책이면 자동 생성하지 않는다. 확인된 관리 위치에 호스트 파일 도구 또는 `record_save`로 새 메모를 한 번 만든다. Taskweave MCP는 조회·현재 작업 찾기·저장만 맡는다. 과거 작업을 검색·재사용하지 않는다.
4. 원인 후보·반증과 수정 전 실패/수정 후 통과할 직접 테스트를 확인한다. 수치 경계는 직전·경계·직후를 포함한다. 외부 계약·다중 저장소·보안·의료 데이터는 필요한 근거를 더 확인한다.
5. 원인·파일·수정 방향·검증이 확정된 직접 경로는 부모가 계획한다. 그 밖에는 [모델 라우팅](../../references/model-routing.md)과 model-route --stage planning --model <model> --available-model <실제-후보> ...로 필요한 계획 agent를 실행한다. 모델 세대·실제 실행·부모 쓰기 소유권은 기존 정책을 유지한다.

## 필요한 문서 선택

- 모든 승인안 작성: [구현 인계의 공통 설명 작성 원칙](../../references/implementation-handoff.md#공통-설명-작성-원칙)을 읽고 본문과 상세 코드 설명에 적용한다. 부족한 재현 원천·제품 결정·복잡한 인계는 같은 문서의 질문·재개 기준을 따른다. 코드로 확인할 사실은 직접 조사하고 질문 후 같은 draft에서 재개한다.
- UI 오류: [디자인 시스템 계약](../../references/design-system-implementation-contract.md)과 [UI 검증](../../references/ui-verification.md). 영향 View·state·원천·검증 단계를 정하고 구현 직전 읽을 rule leaf·선언을 인계한다.
- 비자명한 원인·제약을 주석으로 보존: [주석 계약](../../references/code-comment-contract.md).
- 기록 형식이 필요할 때: [승인안 예시](references/approval-packet.md).

## 승인안

승인 요청 전에 위 공통 원칙으로 본문과 연결된 상세 코드 설명을 함께 확인한다. 어떤 입력·행동이 어느 코드에서 잘못된 결과를 만들고, 수정 후 누가 무엇을 다르게 처리하며 회귀 테스트가 이를 어떻게 확인하는지 설명한다. 문서 검사 성공만으로 설명이 충분하다고 판단하지 않는다.

증상·원인 코드·수정 후 코드·caller·유지할 정상 동작·제외 범위와 직접 회귀 검증을 연결한다. 여러 경로의 오류는 선택적 `## 구현 구상`에 실제 언어로 흐름을 보여 준다. 새 메모의 `## 검증 계획`에 재현 조건·파일·test ID·명령·통과 기준을 적고 제외 검증의 이유를 남긴다. 긴 보고서·source graph·knowledge 문서를 만들지 않는다.

UI Snapshot 필요 여부와 none|regression|conformance|full은 원천·Golden 출처에 따라 정한다. 필요한 Golden이 없으면 원천 대조 경로를 계획하며 부재를 완료 단계의 문제로 미루지 않는다. 원인·책임·원천·검증이 부족하면 먼저 질문하고 승인 준비를 멈춘다.

AI가 한글 원인·컨셉·현재/제안 코드·검증 계획·계획 버전을 직접 보여 준다. 그 응답은 승인 요청으로 끝내고 사용자가 해당 계획 버전을 명시 승인할 때까지 기다린다. 최초 수정 요청·기준 합의·bugfix-apply 동시 호출을 승인으로 해석하거나 스스로 승인 출처를 만들지 않는다. 승인 뒤 /taskweave:bugfix-apply가 같은 메모에서 이어간다. 계획 중 제품 코드·테스트·Product Memory·Jira 구현 상태를 바꾸지 않는다.

문서 제목·필드·설명 형식 부족은 경고하고 끝에 보완한다. 기존 MCP/CLI의 prepare·validate·approve·apply 성공을 새 Taskweave 진행 조건으로 요구하지 않는다. 실제 원문·원인·제품 결정 부족은 그 정보만 확인하며 형식 문제와 구분한다. 기존 schema·revision·gate 실행 이력은 보존하고 자동 변환·같은 승인 반복은 하지 않는다.
