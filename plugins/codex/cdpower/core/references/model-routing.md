# 위험에 따른 모델 선택

작업 모델은 단계 이름이 아니라 현재 위험과 불확실성으로 선택한다. 고정된 `계획=고성능`, `구현=저비용` 매핑을 사용하지 않는다.

모델 이름을 Workplan에 기록하는 것만으로는 모델이 바뀌지 않는다. 다만 모든 구현이 별도 agent를 필요로 하지는 않는다. 아래 직접 구현 경로는 현재 부모가 수행하고, 위임 구현 경로만 `model-route`가 반환한 `agent_type`으로 실제 agent를 생성한다.

Codex 위임 모델은 현재 실행 도구가 지원하는 모델 목록에서 고른다. **GPT-6·6.x가 하나라도 실행 가능하면 GPT-5·5.x를 후보에서 모두 제외한다. GPT-6 계열이 전혀 없다는 것이 확인될 때만 GPT-5 계열을 사용한다.** 특정 역할의 선호 모델 또는 custom agent 호출이 실패했다는 이유만으로 GPT-5로 내려가지 않는다. 가용성을 확인하지 못한 상태도 GPT-6 부재로 간주하지 않는다.

Codex 코드 작업의 계획·구현·리뷰에서는 Astra 계열을 선택 후보와 대체 dispatch 모두에서 제외한다. Astra가 더 최신이거나 다른 모델이 없더라도 선택하지 않는다. GPT-6 존재 여부는 필터 전 전체 목록으로 판정하므로 GPT-6가 Astra뿐이라는 이유로 GPT-5에 내려가지 않는다. 제외 뒤 허용 후보가 없으면 실행 가능한 모델이 없다는 오류를 보고한다.

기존 `terra/luna/spark/sol` 키와 `agent_type` 이름은 역할 호환성을 위해 유지한다. 기본 agent 선언은 Terra=`gpt-6.1-sol`, Luna/Spark=`gpt-6-luna`, 최상위 Sol=`gpt-6.1-sol`이다. 선언은 가용성 증거가 아니며 라우터는 현재 실행 도구가 지원하는 목록에서 고른다. Terra는 sol/terra, Luna/Spark는 luna 계열의 기존 선호를 유지한다. 최상위 `sol` 역할은 해당 세대의 Sol 계열만 허용하고 숫자 버전으로 최신 minor를 선택한다. 허용 Sol이 없으면 Astra·Terra·Luna로 조용히 대체하지 않는다. Spark와 Luna는 같은 모델을 사용하더라도 허용 작업 범위와 역할 지침이 다르다. 현재 부모 모델 자체와 이미 실행 중인 다른 대화의 모델은 이 라우터의 제어 대상이 아니다.

`model-route --available-model MODEL`을 반복해 **현재 실행 도구의 전체 모델 목록**을 전달한다. 역할별로 목록을 미리 걸러 GPT-6를 숨기지 않는다. 목록 누락 또는 GPT-6/GPT-5 후보 부재는 오류로 처리한다. `dispatch_attempts`에는 선택한 동일 모델만 사용하므로 default 호출에서 세대가 바뀌지 않는다. 선택된 모델의 지원 추론 수준도 실제 도구 설명에서 확인하고, 해당 역할의 필요한 추론 수준을 지원하지 않으면 후보를 재검토하거나 제한을 보고한다.

Claude Code에서는 같은 위험 기반 role을 사용하되 Codex의 GPT 모델명을 이식하지 않는다. 좁고 결정적인 `routine`·`ui-narrow`는 `fable`, 일반 작업은 `sonnet`, 고위험 작업은 `opus` 별칭을 사용하며 Haiku는 사용하지 않는다. 별칭은 설치된 Claude Code가 제공하는 최신 모델 버전을 선택한다. `runtime-bin model-route --client claude --stage ... --model ...`은 이 Claude role과 실제 alias를 반환한다. Claude subagent dispatch가 불가능하면 `dispatch_unavailable`을 기록하며, Codex 모델이나 실행하지 않은 role이 사용됐다고 기록하지 않는다.

## 직접 구현 경로

아래 조건이 조사로 모두 확정된 작업의 계획은 부모가 작성한다. 단순히 문서 형식을 확인하기 위해 planning/review agent를 추가하지 않는다. 조건을 만족하지 않는 계획·구현·리뷰의 실제 위임은 아래 기본 라우팅과 실행 절차를 따른다.

다음 조건을 모두 만족하면 별도 implementation/review agent를 만들지 않는다.

- 단일 저장소이며 변경 파일과 심볼 또는 정확한 literal이 확정됐다.
- 원인, 제안 코드와 1~3개의 직접 검증이 승인 메모에 확정됐다.
- Public API, 외부 계약, 서버·BLE·펌웨어, 저장 형식, 보안·의료 데이터 의미와 새 아키텍처 판단을 바꾸지 않는다.
- 현재 작업에서 동일 원인의 구현·검증 실패가 반복되지 않았다.

부모는 대화 코드 승인 또는 Workplan apply와 필요한 ticket 시작 동기화 뒤 즉시 구현·직접 검증한다. 별도 planning/review agent를 추가하지 않으며 최종 diff를 승인 범위와 직접 대조한다.

## 기본 라우팅

| 경로 | 사용 조건 | 금지·중단 조건 |
| --- | --- | --- |
| Terra | 일반적인 단일 저장소 조사·계획·구현·리뷰의 기본값 | 고위험 조건이 확인되면 Sol로 승격 |
| Luna | 파일·심볼·변경 패턴·직접 테스트가 모두 확정된 결정적 반복 작업 | 제품 판단, 아키텍처 선택, 외부 계약 해석 또는 새 불확실성이 생기면 중단 |
| Spark | Luna 조건을 만족하면서 기존 컴포넌트·token만 쓰는 매우 좁은 UI 변경 | 상태·데이터 흐름 변경, 새 공통 API, Figma 해석 또는 원천 적합성 판단이 필요하면 사용 금지 |
| Sol | 모호성·상충·고위험 계약·넓은 영향의 조사, 계획, 구현 또는 리뷰 | 단순 반복 작업의 관성적 기본값으로 사용하지 않음 |

## Sol 강제 조건

다음 중 하나면 Sol을 사용한다.

- 원천끼리 상충하거나 요구사항·원인·책임 경계가 불명확하다.
- 여러 저장소를 함께 변경한다.
- Public API, 서버 API, BLE·펌웨어, 저장 형식이나 데이터 마이그레이션을 바꾼다.
- TCA·DI·Flow·모듈 책임 경계나 concurrency·effect lifecycle을 새로 설계하거나 바꾼다. 대상 Feature의 확립된 Action case와 기존 effect 패턴을 그대로 재사용하는 좁은 추가만으로는 Sol을 강제하지 않는다.
- 보안·개인정보 계약 또는 의료 값의 계산·저장·전송·접근 제어·임상적 해석을 바꾼다. 값과 의미를 바꾸지 않는 기존 의료 값의 표시 형식·배치만 조정하는 작업은 그 이유만으로 Sol을 강제하지 않되 원천·UI·검증 불변식은 유지한다.
- Design System public component나 token 계약을 새로 만든다.
- 동일 원인의 구현·검증 실패가 반복됐거나 현재 테스트가 원천 적합성을 증명하지 못한다.

## 승격과 리뷰

- 실행 중 새 불확실성이 발견되면 `Spark 또는 Luna → Terra → Sol` 순서로 즉시 승격한다.
- 모델 승격 자체는 승인 범위 변경이 아니다. Public API·데이터 계약·저장소·주요 동작이 달라질 때만 재승인한다.
- 위임된 Spark·Luna 결과는 Terra가 실제 diff와 직접 검증 근거를 리뷰한다. 직접 구현 경로는 별도 review agent 없이 부모가 같은 대조를 수행한다.
- Terra 결과는 고위험 조건이 발견되면 Sol 리뷰로 승격한다.
- Sol 작업과 Sol 강제 조건이 있는 변경은 Sol이 리뷰한다.
- 계획 단계의 기본 review는 planning agent 한 번의 원천·코드·계획 대조다. 같은 계획에 별도 review agent를 추가하지 않으며, 서로 다른 허용 원천이 해결되지 않는 상충을 보일 때만 Sol plan review를 추가한다.

## 단계별 실제 실행

| 단계 | 허용 모델 | agent 책임 | 부모 책임 |
| --- | --- | --- | --- |
| 계획 | Terra, Sol | 읽기 전용 조사·계획 review, 근거·질문·계획 초안 반환 | Jira·원천 권한, Workplan 작성, 승인 질문 |
| 구현 | Terra, Luna, Spark, Sol | 승인된 파일·코드·테스트만 수정하고 실행 증거 반환 | 승인 revision·Jira·Workplan 상태, 범위 변경 판단 |
| 리뷰 | Terra, Sol | diff·직접 테스트·승인 범위를 독립 대조하고 `pass/concern/block` 반환 | 최종 판정, 후속 수정·완료 처리 |

1. `"${AI_RUNTIME_BIN:-$HOME/.codex/bin}/model-route" --stage planning|implementation|review --model <model> --available-model <현재-지원-모델> ...`로 agent를 해석한다. Codex는 현재 도구의 전체 목록을 반복 flag로 전달한다. Claude 분기에는 GPT 목록을 요구하지 않는다.
   - Codex 출력의 `dispatch_attempts`는 조건부 실행 순서다. 현재 custom role이 선택 모델과 일치할 때만 1번을 호출한다. `agent type is currently not available`이면 즉시 2번 `default`와 동일 모델을 한 번 호출한다. 현재 세션의 custom 모델이 다르면 1번은 호출하지 않고 2번으로 간다. GPT-6가 선택됐을 때 캐시된 GPT-5 custom role을 호출하지 않는다.
   - `dispatch_evidence_required: true`이면 실제 agent tool call 결과가 있어야만 호출·재시도 성공 또는 실패를 보고할 수 있다. tool call 없이 “다시 호출했다”거나 “여전히 unavailable”이라고 보고하지 않는다.
2. 위임 구현 경로이고 협업 agent 실행 기능이 있으면 실행 도구가 현재 세션에 표시하는 custom `agent_type`의 실제 모델을 먼저 확인한다. resolver가 반환한 모델과 일치할 때만 그 custom agent를 생성한다. 계획·리뷰는 읽기 전용이며 구현 agent만 승인된 코드 범위를 쓸 수 있다.
   - 설치 직후처럼 custom role이 현재 세션에 없거나 실제 모델이 다르면 `agent_type: default`에 resolver가 반환한 동일한 지원 모델과 `reasoning_effort`, 해당 역할의 지침을 명시해 한 번만 실행한다. 다른 모델로 바꾸거나 반복 호출하지 않는다. 가용한 GPT-6 후보가 남아 있으면 목록을 확인해 그 세대 안에서만 다시 선택할 수 있으며, 특정 호출 실패로 GPT-5 fallback을 허용하지 않는다.
   - custom role과 이 호환 호출이 모두 실패하면 `dispatch_unavailable`로 기록한다. 현재 작업은 직접 구현 경로 조건을 만족할 때만 부모가 이어받고, 그렇지 않으면 실행 제한을 구체적으로 보고한다.
3. agent prompt에는 목표, 승인 revision, Workplan·코드 경로, 소유 파일, 제외 범위, 직접 테스트와 반환 형식을 전달한다. UI 수정이면 [Design System Implementation Contract](design-system-implementation-contract.md)의 pre-edit 읽기와 실제 확인할 rule leaf·declaration·layout API도 함께 전달한다. 전체 대화를 복제하지 않는다.
4. 부모는 agent 결과를 실제 diff·실행 증거와 대조하되 동일 입력의 테스트를 다시 실행하지 않는다. agent가 120초 안에 실제 diff·검증 진행을 반환하지 않거나 미완성으로 끝나면 같은 agent에 반복 위임하지 않는다. 현재 작업이 직접 구현 경로 조건을 만족하면 부모가 같은 승인 범위를 인계한다. 고위험 조건이 남으면 다른 적합한 agent로 한 번 승격하고, 그래도 실행할 수 없을 때만 구체적인 위험과 필요한 결정을 보고한다. 내부 위임 방식만 바꾸기 위해 사용자에게 `예외 승인`을 요구하지 않는다.
5. 실행 기능이 없거나 custom role과 동일 지원 모델의 호환 호출이 모두 실패하면 `dispatch_unavailable`을 기록한다. 직접 구현 경로 조건을 만족할 때만 부모가 인계하고, 그렇지 않으면 선택 모델이 실제 사용됐다고 보고하거나 부모 모델로 조용히 대체하지 않는다.
6. Spark·Luna가 불확실성을 반환하면 같은 agent에게 범위를 넓히지 않고 Terra 또는 Sol agent를 새로 생성한다. 모델 승격과 실제 사용 모델은 구현 뒤 approval memo의 `Completion.md`에 기록한다.

### agent 매핑

| 모델 값 | agent_type |
| --- | --- |
| `terra` | `general-terra` |
| `luna` | `routine-luna` |
| `spark` | `ui-spark` |
| `sol` | `high-risk-sol` |

## 에이전트 책임

- 상위 에이전트는 승인, Jira·Workplan, 지식 수명주기, 완료 판정과 Git 전달을 소유한다.
- 작업 에이전트는 승인된 코드·테스트 범위만 수행하고 변경 파일, 핵심 diff, 실행 증거와 남은 위험을 반환한다.
- 작업 에이전트는 범위가 달라지면 추정해서 확장하지 않고 중단 사유를 반환한다.
- 서브에이전트는 전체 토큰을 늘릴 수 있으므로 독립적이고 경계가 명확한 작업에만 사용한다. 목적은 Sol과 상위 Context의 불필요한 사용을 줄이는 것이며 총 토큰 감소를 보장하지 않는다.

## Workplan 기록

Workplan 경로의 코드 변경 계획에는 다음을 기록한다. 대화 코드 승인 경로에서 위임이 필요하면 선택 이유와 실제 실행 모델을 대화에 보고하고 기록을 위해 Workplan을 만들지 않는다.

- `planning_model`: `terra | sol`
- `planning_routing_reason`: 계획 모델 선택 근거
- `implementation_model`: `terra | luna | spark | sol`
- `implementation_routing_reason`: 선택 조건과 배제된 고위험 조건
- `review_model`: `terra | sol`

계획 이후 조건이 바뀌면 실제 사용 agent·모델과 승격 사유를 approval memo 결과에 남긴다. 선택값과 실제 agent가 다르거나 agent 실행 증거가 없으면 해당 단계의 모델 라우팅을 통과로 기록하지 않는다. `model-route`와 그 단위 테스트는 허용 mapping을 해석할 뿐 agent 생성 성공을 증명하지 않으며, 실제 dispatch 결과만 실행 증거다. 레거시 Workplan은 기존 기록 위치를 유지한다.
