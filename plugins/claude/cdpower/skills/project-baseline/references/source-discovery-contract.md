# Source Discovery Contract

## 목적

프로젝트 기준선은 코드 구조만 설명하지 않는다. 현재 구현을 해석하고 다음 티켓을 준비하는 데 필요한 기획·디자인·API·기기·데이터·운영 원본이 어디에 있는지 찾고, 접근 여부와 최신성을 기록한다.

원본의 전문을 기준선에 복사하지 않는다. 원본 시스템의 안정적인 식별자와 revision을 남기고 필요한 주장만 근거와 함께 요약한다.

## 원천 분류

| 분류 | 대표 후보 | 주로 답하는 질문 |
| --- | --- | --- |
| 제품 의도 | Jira, 기획서, PPT, 회의 결정 | 무엇을 왜 제공해야 하는가 |
| 디자인 | Figma, prototype, 디자인 시스템 | 사용자가 어떤 상태와 흐름을 경험하는가 |
| 서버 계약 | OpenAPI, Swagger, Postman, Router, DTO | 요청·응답·오류·버전 계약은 무엇인가 |
| 기기 계약 | BLE·FW 명세, Packet, Command, Characteristic | 기기와 어떤 순서·형식으로 통신하는가 |
| SDK·외부 계약 | Public protocol, 배포 문서, 외부 SDK 문서 | 소비자가 의존하는 호환성은 무엇인가 |
| 데이터 계약 | Schema, Migration, DB, cache, Keychain, 파일 | 무엇을 누가 저장하고 어떻게 이전하는가 |
| 구조·결정 | Architecture, ADR, 저장소 지침 | 책임과 의존 방향을 왜 선택했는가 |
| 운영 | 환경, Feature Flag, CI, 배포, 로그, 모니터링 | 어떻게 실행·배포·관찰·복구하는가 |
| 검증 | Test, Fixture, Mock, Sample App, QA 기록 | 어떤 동작이 실제로 증명됐는가 |
| 역사 | PR·MR, Git history, Event, incident | 언제 왜 바뀌었는가 |

## 발견 순서

1. 수집 스크립트로 저장소 안의 후보 경로를 찾는다.
2. Workspace·manifest·config에서 연결된 저장소와 생성 코드 원본을 찾는다.
3. 회사 작업공간이나 프로젝트 설정에서 Jira·기획·Figma·팀 위키의 논리 연결점을 찾는다.
4. 기능 인벤토리의 각 행에 관련 원본을 연결한다.
5. 기준선에 필요한 원본만 읽고, 나머지는 위치와 적용 범위만 기록한다.
6. 원본이 보이지 않으면 조사한 범위를 적은 뒤 `not_found`, 접근할 수 없으면 `inaccessible`로 구분한다.

## 원천 기록 필드

| 필드 | 내용 |
| --- | --- |
| Source ID | 저장소 안 상대경로, 문서 ID, 티켓 ID, Figma node URL 같은 안정 식별자 |
| 종류 | 제품·디자인·서버·기기·데이터·운영·검증 등 |
| 적용 범위 | 제품, Facade, 기능, 버전 |
| 상태 | draft, approved, deprecated, unknown |
| revision | Git SHA, 문서 버전, 수정 시각, API version |
| 접근 | available, inaccessible, not_found |
| 사용 목적 | 기준선 근거, 티켓 확인, 외부 결정 필요 |
| 충돌 | 다른 원본·코드·테스트와 다른 주장 |

개인 컴퓨터 절대경로를 공유 식별자로 사용하지 않는다. 로컬 파일만 존재하면 논리 저장소 ID와 상대경로를 함께 기록한다.

## 계약별 최소 확인

### 서버 API

- 환경과 base URL 해석
- 인증·토큰 갱신
- method·path·request·response
- 필수·nullable·default·enum·단위·날짜 형식
- 오류 변환, timeout, retry, idempotency, pagination
- API version과 하위 호환성
- 개인정보·암호화·로그 노출

### 기기·BLE

- 지원 기기·chipset·FW version
- service·characteristic·command·packet
- byte order, checksum, ACK, 순서
- timeout, retry, 중단, 복구
- notification과 background trigger
- 세대·플랫폼별 차이

### 데이터 저장

- 상태와 데이터 소유자
- schema와 migration
- cache·영구 저장 구분
- 중복·재시도·복구를 좌우하는 key
- 보존·삭제·개인정보 정책

## 상충 처리

- 현재 실제 동작은 코드와 실행 테스트에서 확인한다.
- 의도와 외부 계약은 승인된 원본에서 확인한다.
- 배포된 소비자 계약은 공개 API와 실제 배포 버전을 함께 확인한다.
- 원본과 코드가 다르면 오래된 쪽을 추측하지 말고 `Conflict`로 남긴다.
- 구현되지 않은 기획을 현재 동작으로 기록하지 않는다.

## 완료 조건

- 기능 인벤토리의 중요 기능마다 현재 코드 근거와 관련 원본 또는 원본 부재가 연결됐다.
- API·기기·데이터 계약의 원본과 구현 위치를 구분했다.
- 접근 불가·버전 불명·상충 원본이 별도 목록에 남았다.
- 다음 티켓에서 원본을 다시 찾기 위해 개인 컴퓨터 경로를 추측할 필요가 없다.
