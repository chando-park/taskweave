# Reapproval Rules

같은 승인으로 계속할 수 있는 것은 메모의 의미 범위 안에서 발견한 구현 세부와 correction이다.

다음은 구현을 멈추고 같은 Workplan을 재승인 대상으로 만든다.

- Public API, 서버·BLE·펌웨어·데이터 계약 또는 저장 형식 변경
- target repository·제품·주요 사용자 동작 변경
- 메모에 없던 책임 경계·상태 흐름·dependency 추가
- UI의 승인되지 않은 component/token/Variant/state 또는 source 기준 변경
- 최소 검증으로 승인 위험을 다룰 수 없는 변경

현재 목적과 독립된 결함·기능은 새 Workplan이다. Jira가 연결됐으면 현재 Workplan+event+revision의 정확한 marker만 제한적으로 동기화한다. 지식 후보나 결과 파일의 행정 보완은 구현 scope 재승인 사유가 아니다.
