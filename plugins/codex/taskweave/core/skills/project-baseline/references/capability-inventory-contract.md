# Capability Inventory Contract

## 목적

기능명을 이미 알고 있다는 가정 없이 공개 API, 조립 구조, 자동 이벤트와 외부 효과에서 제품 기능과 시스템 프로세스를 발견한다. 기준선에는 얕은 지도만 남기고 실제 티켓에서 관련 흐름만 깊게 추적한다.

## 구분

- `Capability`: 사용하거나 의존할 수 있는 제품·시스템 능력
- `Process`: capability를 수행하는 시작 조건과 상태·데이터 흐름
- `Contract`: 둘 이상의 주체가 함께 지켜야 하는 입력·출력·순서·호환성
- `Mechanism`: 클래스, 함수, mapper 같은 내부 구현 수단

기준선은 capability, 중요한 process와 contract를 기록한다. 코드에서 쉽게 다시 찾는 mechanism 목록은 만들지 않는다.

## 발견 표면

1. 제품, Facade, 앱 target, 서비스 executable
2. 공개 protocol, route, 화면 action, CLI command
3. Assembly, Composition Root, DI registration
4. UseCase, Workflow, Coordinator
5. Notification, callback, delegate, event parser
6. background task, timer, scheduler, queue, hook
7. API endpoint와 upload·download side effect
8. device command, packet, characteristic
9. DB·파일·cache·Keychain·UserDefaults 쓰기
10. feature flag, chipset, prefix, OS와 version gate
11. test, fixture, mock, sample app

공개 API만 조사하지 않는다. 호스트에 노출하지 않고 내부에서 처리하는 알림과 자동 프로세스도 반드시 분류한다.

## 인벤토리 필드

| 필드 | 내용 |
| --- | --- |
| Capability | 사람이 이해할 수 있는 기능 이름 |
| 제품·Facade | 기능을 제공하거나 소비하는 제품 경계 |
| 지원 범위 | 기기·chipset·OS·FW·API version |
| Trigger | 공개 API, UI, 알림, timer, background 등 시작점 |
| Owner | 상태와 흐름을 소유하는 module·workflow·use case |
| 주요 경계 | 앱·SDK·서버·기기·DB 사이 연결 |
| 외부 효과 | 서버·기기·영구 저장·사용자 알림 변경 |
| 원천 | 기획·디자인·API·기기 명세 위치 |
| Evidence | 코드 경로·심볼·테스트와 commit |
| Depth | discovered, mapped, traced, verified |
| Priority | critical, standard, code-only |
| Gap | 미지원·no-op·고아·상충·미확인 |

## 중요도 판정

다음 중 하나라도 해당하면 `critical`로 분류하고 기준선에 상태·데이터·오류·동시성의 큰 흐름을 남긴다.

- 측정 정확성, 안전, 인증, 권한 또는 중요한 사용자 데이터에 영향을 준다.
- 사용자 호출 없이 자동 또는 background에서 실행된다.
- 앱·SDK·서버·기기 중 셋 이상의 경계를 통과한다.
- 기기 명령, 서버 변경, 영구 저장처럼 되돌리기 어려운 외부 효과가 있다.
- 중복, 재시도, 복구, migration 상태를 저장한다.
- scheduler, actor, queue, task ordering이 정확성에 영향을 준다.
- 제품·기기·chipset·OS·버전별 동작 차이가 있다.
- Public API나 기존 소비자 호환성에 영향을 준다.
- incident와 회귀 이력이 있거나 실패 시 복구 절차가 필요하다.

단순 조회나 부작용 없는 변환은 `standard`로 얕게 기록한다. 내부 helper·mapper·파일 목록은 `code-only`로 분류하고 기준선 본문에 나열하지 않는다.

## 다제품 지원 표

여러 제품이나 Facade가 한 저장소에 있으면 capability별로 다음 상태를 명시한다.

- `supported`: 실제 조립과 실행 경로가 있음
- `unsupported`: 공개적으로 지원하지 않음
- `no-op`: 이벤트나 protocol은 있으나 주입된 처리가 없음
- `partial`: 일부 경로만 존재하거나 외부 구현이 필요함
- `unknown`: 지정 범위에서 근거를 찾지 못함

공유 module이 존재한다는 이유만으로 모든 Facade가 기능을 지원한다고 추정하지 않는다. 각 Composition Root와 공개 계약에서 확인한다.

## 고아 검사

다음을 기능에 연결하거나 확인 필요로 남긴다.

- Assembly에 주입됐지만 공개·자동 trigger를 찾지 못한 UseCase
- parser에는 있으나 전달·처리·무시 정책이 불명확한 이벤트
- 호출자를 찾지 못한 endpoint·command·영구 저장 쓰기
- 공개 API에는 있으나 구현 또는 검증 근거가 없는 기능
- 문서에는 있으나 현재 코드 경로가 없는 기능

## 기준선 완료 조건

- 모든 제품·Facade가 지원 표에 있다.
- 모든 공개 API 책임군이 capability에 연결됐다.
- 모든 자동 이벤트가 `전달`, `내부 처리`, `무시`, `미구현`으로 분류됐다.
- 중요한 endpoint·device command·영구 저장 쓰기가 capability에 연결됐다.
- critical capability는 시작점·상태 소유자·외부 효과·실패 경계가 요약됐다.
- 고아와 미확인 항목이 숨겨지지 않고 별도 목록에 있다.

## 티켓 추적 중단 조건

다음을 근거로 설명할 수 있으면 구현 계획으로 넘어간다.

- 왜 이 경계를 변경하는가
- 입력부터 외부 효과까지 어떤 흐름이 영향을 받는가
- 기존 소비자와 제품 변형에 어떤 영향이 있는가
- 오류·취소·재시도·동시성을 어떻게 유지하는가
- 수정 전후를 어떤 테스트로 증명하는가

남은 미확인 사항이 변경 범위 밖이면 기록하고 멈춘다. 변경 결과를 바꿀 수 있으면 더 조사하거나 사람의 결정을 요청한다.
