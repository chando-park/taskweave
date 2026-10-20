# Ticket Lifecycle Contract

회사 Jira와 Workplan은 같은 작업을 추적하지만 서로의 저장 구조를 직접 알지 않는다. provider·project·issue type·status 이름은 활성 회사 workspace의 `ticket_policy`가 소유한다. 공통 Runtime에 회사 URL, key, board/status/transition ID를 하드코딩하지 않는다.

## 새 작업 기록

- `company-project`의 새 bug·feature에서 정책이 티켓을 요구할 때만 현재 요청용 구현 티켓을 생성하거나 사용자가 제공한 정확한 issue key를 연결한다.
- 새 작업을 찾기 위해 Jira 과거 이력, 유사 제목, 과거 Workplan 전체를 검색하지 않는다. 사용자가 준 정확한 key나 현재 메모에 이미 기록된 key만 좁게 조회한다.
- 새 티켓에는 bug의 관찰·기대·재현 근거 또는 feature의 목적·범위·완료 조건을 기록하고 미확정 원인을 사실로 쓰지 않는다. 회사 정책의 기본 담당자와 사용자 시간대 당일 시작일·기한을 생성 요청에 포함하고 재조회해 확인한다.
- 외부 QA·CS·운영 티켓이 원천이면 `source_ticket`으로 보존하고 정책이 요구하는 구현 티켓과 연결한다.
- 개인 작업과 Investigation의 초기 읽기 전용 조사는 회사 티켓을 만들지 않는다.

정책 또는 사용자가 제공한 ticket key는 approval memo에 보존한다. 티켓 생성·연결·상태 확인이 실패하면 회사 코드를 수정하지 않고 확인된 상태와 안전한 재시도 지점을 보고한다.

## 구현 시작

승인된 메모에 연결 ticket이 있으면 제품 코드를 바꾸기 전에 현재 상태를 읽는다. 이미 정책의 `implementing` category/name이면 멱등 성공이다. 아니라면 실행 시점의 가능한 transition 중 정확히 일치하는 하나만 실행하고 다시 읽어 확인한다. 모호하거나 재확인에 실패하면 Workplan을 승인 상태로 유지하고 구현하지 않는다.

이 시작 동기화는 현재 Workplan의 정확한 key에 대해 `읽기 → 필요 시 전환 → 재확인` 한 사이클만 수행한다. 같은 구현 시작에서 Jira 설명·댓글·과거 상태를 보강하거나 Workplan 본문을 다시 작성하지 않는다. 일시 오류 재시도 한 번 뒤에도 확인되지 않으면 Jira 병목으로 보고하고 다른 준비 작업으로 우회하지 않는다.

새 approval memo에 연결 ticket이 없고 정책이 이를 선택 사항으로 두었다면 티켓을 추정 생성하지 않는다.

## 재승인과 댓글

정책이 `scope-change` 또는 `reapproved` 댓글을 요구할 때만 현재 Workplan+event+revision marker의 정확한 tuple을 조회한다. 없을 때 한 번 작성하고 재조회한다. 과거 issue의 유사 댓글을 넓게 검색하거나 기존 설명을 변경 이력으로 덮어쓰지 않는다.

댓글 실패 여부와 관계없이 의미 범위가 달라진 코드는 재승인 전까지 진행하지 않는다. 댓글에는 변경 전후 범위, 영향 파일·계약·검증, 현재 상태와 다음 행동만 요약하고 민감한 원문을 복제하지 않는다.

## 검증 뒤

구현·검증 성공은 Workplan을 `awaiting_completion`으로 만들 수 있지만 current Jira는 `implementing`에 유지한다. `/taskweave:bugfix-apply`, `/taskweave:feature-apply`, 승인 또는 검증 요청을 Jira 완료 권한으로 해석하지 않는다.

Jira 완료 댓글·transition과 Product Memory 처리는 사용자의 명시적 완료 요청을 받은 `/taskweave:complete-work`만 수행한다. 피드백이 함께 있으면 correction과 재검증을 먼저 끝내고 사용자가 다시 완료를 요청하기 전에는 Jira를 종료하지 않는다.

## 재시도 한도

- 현재 Workplan의 정확한 issue key 읽기와 가능한 transition 조회만 수행한다.
- 일시 오류의 같은 읽기는 한 번만 재시도한다.
- 생성·transition·댓글 쓰기가 timeout 또는 불명확한 응답이면 같은 멱등 key나 marker를 먼저 한 번 재조회한다. 성공이 확인되면 끝내고, 실패가 명확할 때만 같은 쓰기를 한 번 재시도한다.
- 성공 여부를 확인할 수 없거나 정확히 일치하는 경로가 없으면 중복 가능성이 있는 쓰기와 열린 결말의 검색을 반복하지 않는다.

## 레거시 호환

도입 전에 승인된 Workplan의 ticket ID, status와 append-only comment marker는 그대로 유지한다. 새 정책을 이유로 티켓을 다시 만들거나 현재 Jira를 자동 완료하지 않는다.
