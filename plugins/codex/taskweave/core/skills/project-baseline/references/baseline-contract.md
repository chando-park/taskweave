# 프로젝트 기준선 결과 계약

## 목적

기준선은 코드의 복사본이 아니라 향후 작업이 어디서 시작되고 어떤 경계를 지켜야 하는지 알려 주는 얇은 지도다. 기준선의 모든 주장은 특정 원본과 Git commit에 연결한다.

## 조사 깊이와 준비 기준

### 얕은 기준선

프로젝트 목적과 외부 사용자 → 제품·Facade·기능·자동 프로세스 → 실행·조립 진입점 → 모듈 책임·의존 방향 → DI와 수명 → 외부 API·SDK·BLE·저장 계약 → 정확성에 중요한 상태·동시성 → 빌드·테스트·CI → 원본과 코드의 상충 순으로 필요한 파일만 읽는다. 클래스와 호출 관계 전체를 열거하지 않는다.

### 지정 범위 심층 추적

`trace`는 사용자 지정 시작점에서 입력·호출, 상태 소유자·전이, UseCase·Repository·Infrastructure, 변환·저장, 오류·취소, Task·Actor·Queue·Scheduler, 외부 인터페이스·호환성, 테스트·공백을 추적한다. 관련 없는 모듈은 기본 제외하고 결론에 필요한 확장만 이유를 밝힌다.

### 프로젝트 준비 체크리스트

다음을 모두 충족해야 `baseline_ready`다. 일부 제품·Facade가 빠지면 `partial`이며 전체 분석 완료로 표현하지 않는다.

- 제품·Facade·실행 대상과 지원 범위를 분류했다.
- 공개 기능과 숨은 자동 프로세스의 시작점·책임·외부 효과를 얕게 연결했다.
- 기획·디자인·API·기기·데이터·운영 원본의 위치 또는 접근 불가 상태를 남겼다.
- 실행·조립·의존 경계와 변경 금지 계약을 설명할 수 있다.
- 재현 가능한 기본 빌드·테스트 명령과 검증 공백을 확인했다.
- 문서·명세·코드·테스트의 상충과 고아 후보를 남겼다.

### 티켓 구현 준비 체크리스트

해당 변경 범위에서 다음 질문에 근거로 답할 수 있어야 구현 준비 완료다.

1. 현재와 기대 동작은 무엇이 다른가?
2. 무엇이 흐름을 시작하는가?
3. 누가 상태를 소유하고 어떻게 전이하는가?
4. 데이터는 어느 경계를 지나 어디에 저장되는가?
5. 서버·DB·기기에 어떤 외부 효과가 생기는가?
6. 오류·취소·timeout·retry·rollback은 어떻게 처리되는가?
7. 동시성과 실행 순서 제약은 무엇인가?
8. 제품·기기·OS·버전·기존 소비자에 어떤 영향이 있는가?
9. 왜 어느 경계를 수정하고 무엇은 유지하는가?
10. 어떤 직접 회귀 검증으로 기대 동작을 증명하는가?

변경 영향 범위의 답이 빠지면 추가 조사 또는 사람의 결정을 요청한다. 남은 미확인이 범위 밖임을 설명할 수 있으면 조사를 멈춘다.

## Investigation Workplan 계약

회사 프로젝트의 `bootstrap`과 `refresh` 결과는 회사 adapter가 반환한 프로젝트 Workplan root의 고정 bundle `<ID>/<ID>.md`에 두고 `workplan_kind: investigations`로 구분한다. 상태에 따라 폴더를 이동하거나 `investigations` 하위 경로를 추정하지 않는다. 필수 frontmatter는 다음과 같다.

```yaml
id: BASELINE-YYYYMMDD
type: project_baseline
status: investigating
project_id: <registered-project-id>
repository: <registered-repository-name>
remote: <git-remote>
branch: <git-branch>
created: "YYYY-MM-DDTHH:MM:SS+09:00"
updated: "YYYY-MM-DDTHH:MM:SS+09:00"
baseline_commit: <full-sha>
baseline_readiness: partial
verification_status: not_run
knowledge_sync_status: not_evaluated
team_wiki_candidate: none
personal_principle_candidate: none
```

수명주기 시각은 초와 UTC offset을 포함한 따옴표로 감싼 ISO 8601 문자열로 기록한다. 기존 `YYYY-MM-DD` 날짜 전용 기준선은 읽기 호환성을 유지하고 정확한 과거 시각을 추정하지 않는다.

- `status`: `investigating`, `on_hold`, `awaiting_approval`, `knowledge_sync_pending`, `completed`
- `baseline_readiness`: `partial`, `baseline_ready`
- `verification_status`: `not_run`, `passed`, `blocked`, `accepted_with_limitations`
- `knowledge_sync_status`: `not_evaluated`, `not_needed`, `pending_approval`, `synced`
- 지식 후보: `none`, `candidate`, `promoted`

`partial`은 `investigating` 또는 `on_hold`로 유지한다. `baseline_ready`가 되어 사람 검토를 받을 때 `awaiting_approval`로 전환할 수 있다. Product Memory 반영이 승인되면 팀 위키 후보와 지식 동기화 상태를 각각 `candidate`, `pending_approval`로 전환한다. 승격됐거나 승격할 지식이 없다고 결정된 뒤에만 `completed`로 마친다. Investigation에는 구현 완료용 post-verify Hook을 사용하지 않는다.

### 1. 대상 식별

- 논리 프로젝트 ID
- Git remote
- 기준 commit SHA와 조사 시점
- 기준선 범위

### 2. 원천 자료 목록

- 기획·디자인·API·기기·데이터·구조·운영·검증 원본의 안정 식별자
- 원본별 적용 제품·기능·revision·접근 상태
- 코드·테스트와 대조가 필요한 후보
- 접근 불가, 버전 불명과 상충 원본

상세 형식은 [원천 자료 발견 계약](source-discovery-contract.md)을 따른다.

### 3. 목적

- 프로젝트가 해결하는 제품·시스템 문제
- 외부 사용자 또는 상위 시스템
- 프로젝트가 소유하지 않는 책임

### 4. 기능 지도

- 제품·Facade·실행 대상
- 공개 기능과 자동·background 프로세스
- 시작점·책임 경계·외부 효과
- 제품·기기·버전별 지원·미지원·no-op·partial
- 관련 원본과 조사 깊이

상세 형식과 완료 조건은 [기능 인벤토리 계약](capability-inventory-contract.md)을 따른다.

### 5. 진입점

- 앱·SDK·서비스의 실행 또는 공개 진입점
- Composition Root
- 주요 외부 이벤트 진입점

### 6. 안정 경계

경계마다 다음을 기록한다.

- 책임
- 입력과 출력
- 허용 의존 방향
- 변경하면 영향을 받는 소비자
- 근거 등급과 코드·문서 위치

### 7. 중요한 흐름

전체 호출 그래프가 아니라 정확성에 중요한 흐름만 요약한다.

- 상태 소유권과 전이
- 데이터 생성·변환·저장
- 오류 생성·변환·표시
- 동시성·스케줄러·실행 문맥

세부 추적은 `trace` 범위가 있을 때만 작성한다.

### 8. 외부 인터페이스

- Public API
- 앱–SDK·클라이언트–서버·앱–디바이스 계약
- 호환성 및 버전 제약
- 문서만 있고 코드로 확인하지 못한 부분

### 9. 빌드와 검증

- 실제 실행 가능한 빌드·테스트·린트 명령
- 확인한 테스트 타깃
- 수행 결과
- 환경 제약과 증명 공백

### 10. 준비 상태

- `baseline_ready`: 모든 제품·Facade, 기능·자동 프로세스, 원천 위치, 안정 경계와 기본 검증을 얕게 연결함
- `partial`: 일부 제품·Facade 또는 중요한 원천·프로세스가 아직 미분류임
- 티켓 구현 준비 여부는 관련 범위의 입력·상태·데이터·오류·동시성·영향·검증 질문에 답할 수 있는지 별도로 판정함

`partial` 상태에서 특정 티켓을 조사할 수는 있지만, 관련 범위가 티켓 추적으로 보완되기 전에는 구현 준비 완료로 판정하지 않는다.

### 11. 상충과 질문

- 문서와 코드의 불일치
- 코드와 테스트의 불일치
- 서로 충돌하는 원본
- 코드로 결정할 수 없는 제품 질문

## 주장 기록 형식

| 주장 | 근거 등급 | 근거 | 최신성 |
| --- | --- | --- | --- |
| 안정적인 경계 또는 제약 | Declared·Observed·Verified·Inferred·Conflict | 문서 ID, 파일·심볼, 테스트 | commit SHA 또는 원본 revision |

근거 없는 설명, 클래스별 요약, 원문 전문 복사, 개인 컴퓨터 절대경로를 공유 기준선에 넣지 않는다. 기능명만 나열하지 말고 시작점·책임·외부 효과와 지원 범위를 연결한다.

## Product Memory 후보

- 프로젝트의 주요 책임·의존 경계: `Current/Systems`
- 반복 적용할 코드 작성·검증 규범: 프로젝트 범위 `Standards` 초안
- 여러 저장소 또는 디바이스가 함께 지키는 계약: `Current/Interfaces`
- 사용자에게 보이는 안정적인 현재 동작: `Current/Products`
- 조사 원본과 commit: `Sources`
- 실제 검증된 변경: `Events`
- 승인된 선택과 이유: `Decisions`

System에는 적용 Standard 링크와 프로젝트 차이만 두고 Standard 본문을 반복하지 않는다. 단일 프로젝트에서 관찰한 후보는 `scope: project`, `status: draft`로 시작하며 두 System의 독립 근거나 accepted Decision 없이 회사·플랫폼 공통 규칙으로 승격하지 않는다.

최초 분석은 Source와 Current 초안만 만들 수 있다. 분석했다는 사실만으로 Event 또는 verified Current를 만들지 않는다.

기존 팀 위키에 같은 기준선이 있으면 다음 순서로 이관한다.

1. 기존 문서를 후보 Source로 식별한다.
2. 기존 문서의 주요 주장을 현재 commit에서 재검증한다.
3. 그대로 유효한 주장, 오래된 주장, 근거가 없는 추론을 분리한다.
4. 현재 Git remote와 commit SHA를 새 Source에 기록한다.
5. 유효한 주장만 새 Current 초안에 투영하고 기존 문서 위치를 provenance로 남긴다.

## 갱신 판정

다음 중 하나가 바뀌었을 때 기준선 갱신을 검토한다.

- 모듈 책임과 의존 방향
- Public API 또는 외부 데이터 계약
- Composition Root와 DI 방식
- 상태·데이터 소유권
- 동시성·스케줄러 불변 조건
- 제품·Facade별 기능 지원 범위와 자동 trigger
- 외부 원본의 revision 또는 계약 상태
- 빌드·테스트·CI 진입점

함수 내부 구현, 단순 이름 변경, 파일 이동, 일회성 버그 수정은 기존 경계를 바꾸지 않는 한 갱신 대상이 아니다.
