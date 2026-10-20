# Runtime Rule Enforcement

Runtime 원칙은 Markdown 파일이 존재한다는 이유만으로 구현된 것으로 취급하지 않는다.

- `documented_only`: 정본과 의도만 선언되어 있다.
- `connected`: 적용 Skill·template·handoff의 소비 marker가 선언되어 있다.
- `behavior_test_declared`: gate의 성공·실패 행동 test entry가 registry에 선언되어 있다.

새 원칙이나 기존 원칙 변경은 `runtime-rules.yml`에 ID, 정본, 소비 지점과 gate behavior test를 등록한다. mapping만 확인하는 테스트는 `mapping_tests`로 따로 둔다. `audit-runtime-rules`는 선언된 파일의 marker와 test 이름 존재만 확인하며 테스트를 실행하거나 실제 업무의 gate 호출·agent dispatch를 관찰하지 않는다. `verify-runtime.sh`가 이 선언 감사를 수행한 뒤 테스트 파일을 별도로 실행한다.

문구가 있다는 사실만 확인하는 테스트는 행동 증거가 아니다. 중요한 규칙은 가능한 경우 잘못된 입력이 실패하고 올바른 입력이 통과하는 validator·resolver 행동 테스트를 함께 두고 `behavior_test_declared`로 표시한다. 아직 그런 gate가 없으면 `connected`로만 기록한다. 테스트 실행 성공은 gate 동작의 실행 증거이지만 특정 실제 업무에서 그 gate가 호출됐다는 증거는 아니며, 실제 agent dispatch는 도구 결과로 별도 확인한다.

실제 업무에서 읽기만 하고 판정에 쓰지 않은 규칙은 Runtime Evaluation의 `rule_used`로 기록하지 않는다. registry의 구조적 연결과 실제 업무 사용 빈도는 서로 다른 증거다.
