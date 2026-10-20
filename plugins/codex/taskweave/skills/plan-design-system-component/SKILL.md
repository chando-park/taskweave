---
name: plan-design-system-component
description: 공식 Figma 컴포넌트와 기존 디자인 시스템을 대조해 public API·Variant·token·검증을 담은 새 Workplan 승인안을 만든다. 구현은 하지 않는다.
---

# 공통 디자인 컴포넌트 계획

대상·승인은 [실행 계약](../../references/execution-contract.md), 메모·이름·명령은 [Workplan 양식](../../references/workplan-layout.md)을 따른다.

1. target Design System repository·workplan_root·회사 정책을 확인한다. Project Agent가 있으면 먼저 읽고 요청·가까운 코드·테스트에서 변경 범위를 좁힌다.
2. 공식 Figma COMPONENT_SET 또는 단일 COMPONENT와 기존 public component/token/API·consumer·Preview·생성 pipeline을 확인한다. symbol 조사에는 [Serena 절차](../../references/serena-code-intelligence.md)를 사용한다.
3. 회사 정책이 요구할 때 [티켓 절차](../../references/ticket-lifecycle.md)로 정확한 번호를 확보한다. 확인된 기록 위치에 이번 작업 메모를 한 번 만들고 필요한 조사를 이어간다. 과거 작업·Jira 이력을 검색·재사용하지 않으며 기록 형식 검사로 계획 설명을 막지 않는다.
4. [디자인 시스템 계약](../../references/design-system-implementation-contract.md)과 [UI 검증](../../references/ui-verification.md)의 계획 기준으로 public API·token·Variant/property·event·accessibility·소비 코드·검증을 구체화한다.
5. Variant이면 부모 set과 변경 Variant 전체를, 단일 component이면 property·기본값을 확인한다. Guide·Playground·실제 instance의 허용 조합과 override를 공식 source와 구분한다. source 접근이 안 되면 screenshot·componentKey·유사 instance로 대신하지 않고 정확한 원천을 질문한다.
6. 현재 조합/소비 코드와 제안 public API·caller, 변경 파일·제외할 제품 effect/layout·유지 계약, 실제 검증 명령·통과 기준을 보여 준다. public token이 없으면 literal을 발명하지 않는다. 긴 코드만 선택적 Detail로 분리한다.
7. 실제 한글 코드·컨셉·검토 방법을 직접 보여 주고 그 계획의 명시 승인을 기다린다. prepare·validate 문서 형식 검사나 기술적 승인 stamp를 선행시키지 않는다. 필요한 원천·동작 기준이 없으면 그 자료/결정만 질문한다.

conformance/full의 Golden은 원천·candidate 비교와 pre-golden authorization 뒤에만 승격하는 산출물이다. 현재 렌더를 먼저 Golden으로 쓰도록 승인하지 않는다. 코드·codegen·Figma·제품 화면·지식은 계획 중 변경하지 않는다. 승인 뒤 $taskweave:author-design-system-component가 같은 Workplan을 사용하고 레거시 revision·UI receipt·gate는 유지한다.
