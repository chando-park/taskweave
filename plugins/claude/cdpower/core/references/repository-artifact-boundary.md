# Repository Artifact Boundary

제품 저장소는 실행 코드·테스트·리소스·빌드 설정과 제품이 공식적으로 소유하는 기존 문서만 소유한다. AI 작업 과정에서 만드는 계획·조사·아키텍처 분석·구현 설명·검증 보고서·Figma 비교와 Workplan·Product Memory 복제본은 제품 저장소에 두지 않는다. Project Agent의 존재 여부는 이 경계를 완화하지 않는다.

## 기본 배치

| 산출물 | 목적지 |
| --- | --- |
| 작업 계획·조사·변경 설명·검증·Figma 비교 | 회사 중앙 Workplan |
| 검증된 제품 지식·결정·이력 | Product Memory |
| 프로젝트별 AI 연결 규칙 | 중앙 Project Agent |
| 회사·제품에 종속되지 않는 개인 작업 원칙 | 개인 Runtime |
| 코드·테스트·리소스·빌드 설정 | 제품 저장소 |

제품 저장소의 신규 `docs/`, `Docs/`, `.codex/workplans`, 작업용 Markdown과 Workplan·Product Memory 복제는 기본 실패다. 정책을 찾지 못한 경우 새 AI 문서를 허용하는 쪽으로 추정하지 않는다.

Figma source export, 좌우 비교 이미지, 검토용 candidate와 gate receipt는 중앙 Workplan의 `Artifacts/`가 소유한다. 제품 저장소에는 앱이 실제 회귀 테스트에 소비하는 승인 Golden과 테스트 코드만 둘 수 있다. 기존 Snapshot harness·fixture·Demo·Preview를 바꾸는 일은 제품 요구를 검증하는 데 직접 필요하고 승인 artifact에 포함된 경우에만 같은 작업에 넣으며, 단순 UI 보정이라는 이유로 검증 인프라를 새로 만들거나 주변 데모를 확장하지 않는다.

Workplan의 `repository`는 회사 registry가 정한 논리 저장소 ID를 유지한다. 임시 checkout이나 worktree 폴더명으로 바꾸지 않으며, 실제 검증 대상 경로·Git dir·HEAD는 gate의 `--repository`와 repository identity receipt가 별도로 결속한다.

## 기존 공식 문서의 좁은 예외

기존 Git HEAD에 이미 추적 중인 README·DocC·Public API 문서·웹 카탈로그는 다음 조건을 모두 만족할 때만 같은 경로를 갱신할 수 있다.

1. 사용자 원문 또는 티켓이 그 공식 문서의 갱신을 명시한다.
2. repository의 `AGENTS.md` 또는 contribution policy가 해당 문서 소유권과 갱신을 허용한다.
3. Workplan이 `product_owned: true`, `update_existing: true`, `action: update`로 기록한다.
4. policy 파일·SHA-256과 `repository-official-document-policy-v1`의 target path/action 긍정 allow entry가 승인 revision에 포함된다. 단순 marker substring이나 부정 문장 속 경로 언급은 허용 근거가 아니다.
5. gate가 대상 경로가 HEAD에 이미 존재하는 tracked 파일임을 확인한다.

이 예외로 새 문서 위치를 만들거나, 제품 공식 문서에 AI 작업 일지를 섞거나, 기존 문서를 Workplan 대용으로 사용하는 것은 허용하지 않는다.

## 구조화 계획과 실행 게이트

계획의 `Details/description.md` 또는 split 계획의 `Details/code-plan.md`에는 다음 packet을 둔다. `repository_diff_baseline`은 계획 시점 HEAD OID와 각 dirty 경로의 status·Git mode·실제 content SHA-256을 고정한다. 삭제는 HEAD blob의 mode·content hash를 기록한다. 기존 사용자 변경은 completion까지 같은 fingerprint로 보존하고 작업 산출물로 소유하지 않는다.

```yaml
artifact_placement_plan:
  schema: repository-artifact-placement-v1
  repository_diff_baseline:
    head_oid: <계획-시점-HEAD-OID>
    entries:
      "User Draft.bin":
        status: untracked
        mode: "100644"
        hash: sha256:<실제-content-hash>
    digest: sha256:<head_oid와-canonical-entries-hash>
  destination_roots:
    product-memory: /resolver가-반환한-절대-root
    project-agent: /resolver가-반환한-절대-root
    personal-runtime: /resolver가-반환한-절대-root
  artifacts:
    ART-CODE-01:
      destination: product-repository
      path: Sources/Feature.swift
      kind: code
      action: update
      required: true
    ART-WORKPLAN-01:
      destination: central-workplan
      path: Details/verification.md
      kind: verification-report
      action: create
      required: true
```

dirty baseline 경로를 승인 작업이 실제로 소유해야 한다면 artifact에 정확한 `baseline_ownership.before`와 승인된 `after` fingerprint를 함께 둔다. before가 현재 baseline과 다르거나 completion after가 실제 결과와 다르면 실패한다. 소유권 선언이 없는 baseline 경로는 byte·mode·status 하나라도 바뀌면 실패한다.

공식 문서 예외는 같은 artifact에 다음을 추가한다.

```yaml
product_owned: true
update_existing: true
requirement:
  kind: user
  reference: 승인 원문의 공식 README 갱신 요구
repository_policy:
  artifact: AGENTS.md
  hash: sha256:<실제-policy-file-hash>
```

policy artifact에는 다음처럼 기계 해석 가능한 긍정 allow entry가 있어야 한다.

```yaml
repository_artifact_policy:
  schema: repository-official-document-policy-v1
  allow:
    - path: README.md
      actions: [update]
```

단계별 실행은 다음과 같다.

```bash
artifact-placement-gate validate --phase plan <Workplan> --repository <Git-root>
artifact-placement-gate validate --phase apply <Workplan> --repository <Git-root>
artifact-placement-gate validate --phase feedback <Workplan> --repository <Git-root>
artifact-placement-gate validate --phase completion <Workplan> --repository <Git-root>
```

- `plan`: mapping, 목적지, 문서 예외와 계획 시점 diff baseline을 검사한다.
- `apply`: 코드 수정 전에 HEAD OID와 dirty status·mode·content hash가 승인 baseline과 같은지 검사한다.
- `feedback`: 승인 구현 뒤 최종 검토 보정을 시작할 때 사용한다. 승인 product artifact의 기존 diff는 허용하고, 그 밖의 dirty 경로를 `Artifacts/repository-feedback-baseline.json`에 기록해 이후 수정에서 그대로 보존한다. 승인 revision과 원래 apply baseline은 변경하지 않는다.
- `completion`: `git diff --no-renames --name-status -z HEAD --`와 untracked 목록을 대조한다. feedback 영수증이 있으면 범위 밖 파일은 영수증 시점 fingerprint와 일치해야 한다. rename은 old delete와 new create로 각각 승인되어야 하며 공백·개행 경로도 NUL 경계를 보존한다. required 중앙 artifact도 create/update이면 실제 일반 파일·hash 일치, delete이면 부재를 검사한다.
- 중앙 destination은 resolver가 반환한 실제 root 아래 safe-relative path만 허용한다. absolute·traversal·symlink·중복 destination/path와 `.git`·Git admin 경로는 실패한다. 모든 segment는 case-fold하여 `DOCS`, `.GIT`, `.GITMODULES` 같은 대소문자 우회를 동일하게 판정하고 docs 아래는 확장자·kind와 무관하게 공식 문서 예외가 필요하다.

Workplan 자체와 중앙 산출물은 제품 저장소 diff에 포함하지 않는다. 중앙 경로를 제품 저장소 안으로 자동 대체하지 않는다.
