# Localization Contract

사용자에게 노출되는 문구는 코드 literal이 아니라 대상 저장소가 정한 현지화 원천과 접근자를 사용한다. 이 계약은 특정 제품의 리소스 타입·파일명·생성 도구를 소유하지 않는다.

## 적용 범위

- View text, 버튼, Alert, toast, sheet, navigation title
- 접근성 label·hint·value
- local notification과 사용자에게 표시되는 오류·fallback 문구
- 문자열 보간으로 조합되는 사용자 노출 문구

로그, 내부 식별자, 개발 전용 진단 값과 테스트 fixture는 사용자 노출 문구가 아니다. 다만 이름만 보고 제외하지 않고 실제 표시 경로가 없는지 확인한다. Preview·Demo가 제품 UI 계약을 보여 주면 같은 현지화 규칙을 적용한다.

## 계획

1. 저장소 Agent와 context catalog가 연결한 현지화 Standard를 먼저 읽고 상태가 `accepted`인지, 프로젝트가 채택·부분 적용·후보 중 어디에 해당하는지 확인한다.
2. 기존 코드, 리소스 파일과 생성 설정에서 프로젝트의 현지화 원천·접근자·지원 locale을 찾는다. 특정 생성기나 접근자 타입은 Runtime에서 추정하지 않고 프로젝트 Standard와 기준 구현에서 해석한다.
3. 변경되는 사용자 노출 문구마다 기존 key·접근자 재사용 여부와 새 리소스 필요 여부를 기록한다.
4. 새 key가 필요하면 필요한 locale 값과 리소스 생성·갱신 절차를 승인 범위에 포함한다.
5. 서버·기기·외부 SDK가 제공하는 동적 문구는 출처, locale 책임과 앱 fallback 정책을 기록한다.
6. 리소스 원천이나 번역이 준비되지 않았으면 임시 literal로 우회하지 않고, raw key lookup도 대안으로 사용하지 않으며 준비도를 `conditional` 또는 `blocked`로 둔다.

## 구현

- 대상 저장소가 채택한 Standard와 기존 접근자를 사용하며 공통 Runtime의 예시 타입명·생성기·key naming을 제품 코드에 복사하지 않는다.
- 프로젝트 Standard가 생성 접근자를 요구하면 리소스 원천과 생성 절차를 사용하고, Standard가 금지한 raw key 호출이나 wrapper로 우회하지 않는다. `draft` Standard는 강제 규칙이 아니라 조사 근거로만 사용한다.
- 사용자 노출 문구를 먼저 literal로 작성한 뒤 나중에 옮기는 방식을 사용하지 않는다.
- 동적 서버 key처럼 정적 접근자로 표현할 수 없는 경우에는 출처·허용 경계·fallback을 기록하고 프로젝트 Standard가 허용한 lookup 경계에서만 사용한다.
- 코드 생성 리소스는 생성 원천을 수정하고 저장소의 생성 절차를 실행한다. 생성물을 직접 고치지 않는다.
- 승인 이후 새 문구나 locale 범위가 발견되면 승인 범위와 대조하고 필요한 경우 재승인한다.
- 최종 diff에서 추가·변경된 문자열 literal 후보를 찾아 사용자 노출 여부와 리소스 근거를 분류한다. 미분류 후보를 남기지 않는다.

## 검증

- `localization source`: 각 사용자 노출 문구가 연결된 리소스 key·접근자 또는 승인된 동적 출처를 기록한다.
- `locale behavior`: 요구 locale과 fallback 동작을 관련 테스트 또는 render로 확인한다.
- `literal audit`: 변경 diff의 사용자 노출 문자열 literal과 프로젝트 Standard가 금지한 정적 key lookup·wrapper 후보가 0건이거나 모두 사용자 비노출·승인된 동적 lookup임을 근거와 함께 확인한다.
- 빌드, 단위 테스트, Snapshot과 Figma 대조는 문자열 출처를 증명하지 않는다. localization 검증을 별도 완료 근거로 남긴다.
- 미확인 사용자 노출 문구가 있으면 `verification_status: blocked`로 기록한다.
