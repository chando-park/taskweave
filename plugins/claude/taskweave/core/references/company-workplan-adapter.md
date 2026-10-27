# Company Workplan Adapter

개인 시스템과 회사 프로젝트는 다음 고정 입구로 구분한다.

```bash
"${AI_RUNTIME_BIN:-$HOME/.codex/bin}/resolve-workplan-policy" \
  <repository> --kind bug|feature|investigation
```

저장소 식별·허용 workspace 경계는 유지한다. resolver는 대상·기록 위치·정책을 알려 줄 뿐 Workplan/Jira 생성 지시가 아니다. 간단한 수정은 `/taskweave:code-change`에서 대화로 코드·검증을 제시하고 승인받으며 문서는 실제 기록 의무·사용자 요청·인계 필요가 있을 때만 반환된 관리 위치에 작성한다. 복잡한 변경은 승인용 `approval-memo-v1`, 정식 기록이 필수인 간단한 수정은 direct fix를 사용한다. 질문·읽기 전용 조사는 기록을 만들지 않는다.

## Personal System

- `resolve-task-context`가 반환한 기존 project별 `workplan_root`를 사용하되 모든 변경을 정식 Workplan으로 만들지 않는다. 간단한 코드·설정 수정은 작업 문서 하나에 변경과 결과를 함께 기록하며, 복잡하거나 고위험인 코드 변경은 계획을 제시하고 명시 승인을 기다린다. 일반 글쓰기·질문·조사는 해당 작업 규칙을 따른다.
- 회사 Jira, 팀 위키 sync, Product Memory와 회사 hook을 실행하지 않는다.
- `project_agent`는 `null`이며 개인 전역 지침과 저장소 지침을 적용한다.
- 구현·검증 뒤 code-change는 같은 작업 문서에 결과를 갱신하고 정식 Workplan만 기존 `Completion.md` 계약을 사용한다. Git 작업은 별도 요청 범위로 판단한다.

## Company Project

- 정책 JSON의 `repository`, `remote`, `project_id`, `workplan_directory`와 현재 target이 일치해야 한다. 제품 저장소 안 임의 Workplan 경로로 fallback하지 않는다.
- `project_agent`가 있으면 티켓·코드·Product Memory보다 먼저 읽는다. `null`이면 프로젝트별 정책을 추정하지 않는다.
- 새 코드 변경은 선택한 경로의 작업 문서 또는 approval memo를 하나만 만든다. 과거 Workplan·유사 Jira 이력을 훑지 않는다. 사용자가 알려 준 관련 Workplan·티켓 URL은 원천으로 선택해 읽을 수 있지만 그 문서를 새 실행 기록으로 재사용하지 않는다.
- `ticket_policy`가 현재 작업의 티켓을 필수로 요구하는 경우에만 [Ticket Lifecycle](ticket-lifecycle.md)에 따라 Jira를 생성하거나 정확한 기존 issue key를 연결한다. `none`·선택 사항·미확인 정책에서는 자동 생성하지 않는다. 회사 저장소·feature/bug 분류·Workplan 사용 또는 기록 위치가 반환되었다는 사실은 티켓 생성 근거가 아니다. 필수 여부가 불명확하면 해당 정책만 확인하고 추정 생성하지 않는다.
- `repository_agent`, `product_agent`, `project_agent`는 연결점만 소유한다. 개별 사실·승인은 approval memo, 검증된 장기 제품 지식은 Product Memory가 소유한다.
- `workplan_sync: true`면 정책의 script를 사용하되 새 메모 생성·승인·구현 시작·최종 결과처럼 의미 있는 checkpoint만 남긴다. sync 실패는 코드 결과와 분리해 보고한다.
- 계획·적용 단계에서 knowledge 문서나 post-verify 지식 평가를 요구하지 않는다. `/taskweave:complete-work`가 최종 diff·검증으로 지식을 추출·평가하고 사용자 완료 권한 안에서 Product Memory와 Jira 종료를 처리한다.

## 레거시 호환

도입 전에 승인되거나 진행 중인 회사 `stable-bundle-v1`은 정책 resolver로 정확한 ID를 열고 기존 status·revision·Details·sync/hook 계약을 유지한다. 새 memo로 migration하거나 재승인하지 않는다. 레거시 조회는 명시된 기존 작업을 이어갈 때만 수행한다.
