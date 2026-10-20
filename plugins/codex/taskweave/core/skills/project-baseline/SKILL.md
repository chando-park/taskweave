---
name: project-baseline
description: 새 프로젝트의 구조·기능·원천 위치를 코드로 분석하거나 지정한 기능 흐름을 추적한다. 질문은 읽기 전용으로 답하고, 지속 사용할 기준선 생성 요청은 중앙 Investigation Workplan에 기록한다.
---

# 프로젝트 기준선 조사

기준선은 전체 코드의 설명서가 아니라 이후 작업의 시작점과 책임·계약·원천 위치를 알려 주는 얕은 지도다. 코드와 테스트는 현재 구현의 근거이며, 승인된 기획·디자인·API·기기 명세는 의도와 외부 계약의 근거다. 서로 다르면 임의로 한쪽을 정답으로 만들지 않는다.

## 요청에 맞는 조사 모드

| 모드 | 요청 | 기본 산출물 |
| --- | --- | --- |
| `inspect` | 구조 질문·설명·일회성 진단 | 읽기 전용 대화 보고 |
| `bootstrap` | 새 프로젝트를 맡아 지속 사용할 기준선 조사·생성 | resolver가 반환한 중앙 Investigation Workplan |
| `trace` | 지정한 기능·버그·모듈의 흐름 추적 | 관련 범위 보고; 현재 연결된 Workplan이 있을 때만 그 기록 사용 |
| `refresh` | 기존 기준선 갱신 | 기존 기준선과 현재 commit의 의미 있는 차이 |

지속 사용할 기준선 생성 의도가 확인되면 별도의 “저장” 표현을 요구하지 않는다. 모호한 질문은 `inspect`로 처리한다. 질문만으로 Workplan·Product Memory·제품 파일을 수정하지 않는다.

## 처음 확인할 근거

1. [작업 근거 선택](../../references/context-pack.md)에 따라 Git root·remote·commit·현재 변경과 가까운 저장소 지침을 확인한다.
2. `resolve-task-context`로 개인·회사·미등록 경계를 확인한다. 회사는 반환된 Project Agent를 Product Memory보다 먼저 읽고, Agent가 연결한 관련 규칙·현재 구조만 확인한다. 미등록 저장소는 읽기 전용 분석이 가능하지만 프로젝트 ID·공식 지식 경로를 추정하지 않는다.
3. 코드의 심볼·호출 관계를 조사하므로 [Serena 코드 탐색](../../references/serena-code-intelligence.md)의 semantic preflight와 실제 symbol·reference·implementation 도구를 사용한다. Serena가 없으면 이를 숨기거나 기준선 완료로 판정하지 않는다.
4. `scripts/collect-repo-facts.sh <저장소>`로 기본 사실과 자료 후보를 수집한다. 전체 위키·Git 이력을 먼저 읽지 않고 실제 범위에 필요한 문서만 코드와 대조한다.

기존 팀 위키·Product Memory에 같은 기준선이 있어도 조사를 생략하거나 본문을 역복사하지 않는다. 현재 commit에서 유효·오래됨·상충·누락을 구분한다.

## 목적별로 추가할 문서

- `bootstrap` 또는 원천 목록을 조사할 때: [원천 자료 발견 계약](references/source-discovery-contract.md). 기획·Figma·API·BLE/FW·데이터·운영 원본의 위치·revision·접근 상태를 찾되 관련 없는 원문은 정독하지 않는다.
- `bootstrap` 또는 기능 목록을 조사할 때: [기능 인벤토리 계약](references/capability-inventory-contract.md). 제품·Facade·화면·공개 API뿐 아니라 이벤트·스케줄러·저장 쓰기에서 자동 프로세스도 발견한다.
- 지속할 기준선을 쓰거나 준비 상태를 판정할 때: [기준선 결과 계약](references/baseline-contract.md). 얕은 지도·심층 추적 항목과 두 준비 체크리스트는 이 문서의 단일 원본을 사용한다.
- `bootstrap`·`refresh`에서 실제 파일을 쓸 때만: [중앙 산출물 경계](../../references/repository-artifact-boundary.md). 회사는 `resolve-workplan-policy --kind investigation`이 반환한 위치와 지원 계약을 사용하고 필요한 배치 검사를 수행한다.

선택한 문서는 끝까지 읽는다. 다른 모드의 문서까지 선행 로드하지 않는다.

## 조사와 준비 판정

얕은 지도는 목적, 제품·기능·자동 프로세스, 조립·모듈·의존 방향, 상태·데이터·외부 효과와 기본 검증을 연결한다. 모든 클래스·함수를 열거하지 않는다. `trace`는 지정 시작점의 상태·데이터·오류·취소·동시성·영향 소비자만 깊게 확인한다.

주장마다 `Declared | Observed | Verified | Inferred | Conflict`와 파일·심볼·원본 ID·commit 또는 revision을 남긴다. 추론을 확정 계약으로 표현하지 않는다. 접근 불가 자료는 질문으로 연결하며 없는 내용을 만들지 않는다.

모든 제품·Facade의 얕은 지도와 중요한 원천·검증 공백이 분류돼야 `baseline_ready`다. 일부가 미분류이면 `partial`이며, 특정 티켓의 구현 준비는 그 변경 경계의 질문에 답할 수 있는지 별도로 판정한다.

## 기록과 보고

- 공유 기록은 논리 프로젝트 ID·remote·commit·초 단위 조사 시각을 사용한다. 개인 절대경로를 공유 원본 주소로 삼지 않는다.
- `bootstrap`·`refresh`는 중앙 `<ID>/<ID>.md` Investigation 계약을 사용한다. 제품 저장소의 `docs/`·`.codex/workplans`·새 Markdown으로 대체하지 않는다.
- 분석만으로 Product Memory의 Event·verified Current를 만들지 않는다. 지식 반영은 기준선 준비와 사용자 승인 뒤 회사 승격 절차에 인계한다.
- System은 현재 책임·적용 Standard 링크, Interface는 여러 시스템의 안정 계약, Standard는 반복 규칙 후보로 구분한다. 단일 프로젝트 관찰을 회사 공통 규칙으로 승격하지 않는다.
- 프로젝트 Agent 변경은 후보로만 제시하며 명시 요청 없이 수정하지 않는다. 회사 제품 사실을 개인 위키에 복사하지 않는다.
- 보고는 한글로 조사 범위·commit·모드·준비도, 원천/기능 커버리지, 확인 경계, 실행 검증·공백, 상충과 다음 질문을 보여 준다.

기준선 갱신은 책임·의존·공개 계약·조립·상태/데이터 소유권·동시성·검증 체계가 의미 있게 달라졌을 때만 제안한다. 단순 파일 이동이나 내부 구현 변경만으로 전체 기준선을 다시 만들지 않는다.
