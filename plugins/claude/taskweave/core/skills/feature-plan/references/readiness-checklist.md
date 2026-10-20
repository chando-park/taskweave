# Feature Memo Readiness

승인을 묻기 전에 다음만 확인한다.

- 요청 원천과 프로젝트 지침을 실제로 읽었다.
- 기대 동작과 비변경 동작이 구분됐다.
- 주요 파일·심볼의 현재/제안 코드와 caller/assembly가 실제 코드에 맞다.
- Public API·외부 계약·저장 형식·repository 경계의 변경 여부가 명확하다.
- 직접 검증의 명령 또는 식별자, 실패 위험과 통과 기준이 있다.
- UI이면 정확한 원천 state, Design System public contract, tier와 실제 candidate render 계획이 있다.
- 제외 범위와 남은 사람 결정이 보인다.
- 코드·테스트·접근 가능한 원천에서 확인할 사실을 사용자 결정으로 넘기지 않았다. 사용자만 제공할 자료나 결정이 남으면 정확히 질문하고 같은 `draft` Workplan에서 답변을 기다린다.
- `workplan-memo prepare`와 approval validation이 통과했다.

하나라도 구현자가 다시 설계해야 할 정도로 비어 있으면 승인안을 제시하지 않는다. 지식 후보·Product Memory 목적지는 readiness 조건이 아니다.
