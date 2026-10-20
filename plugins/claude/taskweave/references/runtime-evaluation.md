# Runtime Evaluation

Runtime 운영 실험은 실제 업무에서 절차 비용과 실패 방지 효과를 측정한다. 회사 제품 지식을 개인 위키로 복사하지 않으며, 작업마다 새 회고 문서나 Workplan 필드를 만들지 않는다.

## 활성 조건

`"${AI_RUNTIME_BIN:-$HOME/.codex/bin}/runtime-evaluation" active`가 성공할 때만 계측한다. 활성 pilot이 없으면 기존 작업에 어떤 단계도 추가하지 않는다. 계측 실패는 제품 코드·Workplan·Jira 처리를 막지 않고 최종 결과에 누락을 알린다.

## 익명 경계

- case는 `case-01` 형식의 익명 ID만 사용한다.
- 티켓·Workplan ID, 저장소·제품·프로젝트 이름, 경로, URL, 코드와 사용자 노출 문구를 기록하지 않는다.
- `events.jsonl`만 원본이며 `report.md`는 언제든 다시 만드는 파생 View다.
- 계측은 approval memo 내용을 복제하지 않고 route와 lifecycle event만 익명으로 기록한다.

## 수명주기 이벤트

| 시점 | 이벤트 |
| --- | --- |
| 실제 업무 시작 | `case_started` |
| 승인 패킷 준비 | `plan_ready` |
| 사용자 승인 확인 | `approval_received` |
| 코드 변경 시작·종료 | `implementation_started`, `implementation_finished` |
| 검증 시작·종료 | `verification_started`, `verification_finished` |
| 완료 요청 또는 최종 결과 전달 | `completion_requested` |
| 종료 처리 완료 | `completed` |

새 direct 작업도 approval memo를 사용하므로 실제 발생한 계획·승인 이벤트를 기록한다. 계획 대기와 완료 대기는 활성 작업 시간과 분리한다.

## 예외 이벤트

- `user_question`: `product_decision`, `discoverable`, `scope_change`
- `reapproval`: `scope_change`
- `rework`: `missed_source`, `missed_context`, `plan_gap`, `implementation_error`, `verification_error`, `environment`, `scope_change`
- `missed_requirement`: `source`, `context`, `plan`, `implementation`, `verification`
- `verification_retry`: `code`, `environment`, `runner`, `cache`
- `bottleneck`: 선택적으로 `docs`, `jira`, `dispatch`, `compile`, `test_runner`, `ui_render`, `product_memory`, `git`, `environment`와 실제 소요 초를 기록한다. 경과가 의미 있게 길거나 비교할 병목이 있을 때만 쓰며 모든 명령을 계측하지 않는다.
- `rule_used`: 결과의 routing·승인·구현·검증·완료 판정에 실제 영향을 준 Runtime rule ID

문서를 읽었다는 이유만으로 `rule_used`를 기록하지 않는다. 실제 판정에 사용된 경우만 기록하며, pilot의 관찰 대상 중 한 번도 사용되지 않은 항목은 자동 삭제가 아니라 제거 검토 후보가 된다.

## 명령

```bash
runtime-evaluation start --type bug --route direct --risk low \
  --planning-model none --implementation-model luna --review-model terra
runtime-evaluation event --case case-01 --name implementation_started
runtime-evaluation event --case case-01 --name bottleneck --category compile --duration-seconds 180
runtime-evaluation event --case case-01 --name rule_used --rule risk-routing
runtime-evaluation report
```

질문·재작업·누락이 대화에서 명확하면 사용자가 별도 회고를 작성하지 않고 에이전트가 기록한다. 판단할 수 없을 때만 완료 시 한 가지 짧은 확인을 요청한다.
