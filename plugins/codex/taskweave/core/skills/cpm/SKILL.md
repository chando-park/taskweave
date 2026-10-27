---
name: cpm
description: 현재 관련 변경을 commit·commit-push·commit-push-mr 중 명시된 범위로 게시한다. 단독 호출은 commit이며 PR/MR 중복 생성·자동 병합을 하지 않는다.
---

# 커밋·푸시·PR/MR

사용자 요청으로 모드를 먼저 고른다. $taskweave:cpm만 호출되면 commit, “커밋 푸시만”은 commit-push, 명시 PR/MR 요청만 commit-push-mr다. push·게시·병합 권한을 추론하지 않는다.

## 모드별 문서 선택

- 모든 모드: [Git 작업 계약](../../references/git-operation-contract.md), 현재 대상·관련 diff·저장소 지침.
- commit-push: 확인한 remote·branch·푸시 권한을 추가 확인한다.
- commit-push-mr: [provider 게시](references/provider-publishing.md). reviewer 선택이 필요할 때 [reviewer 기준](references/reviewer-selection.md), 본문 생성 때 [MR 본문](references/merge-request-body.md)을 읽는다.
- 기존 검증 근거를 판정·보고할 때: [검증 근거](../../references/verification-evidence.md).

cpm은 테스트·빌드·lint를 자동 재실행하지 않는다. 사용자 명시 요청이 있을 때만 현재 대상 저장소에서 실행한다. README의 검증 명령을 실행 권한으로 해석하지 않으며 결과가 없으면 미실행으로 보고한다.

## 대상·정책 확인

1. resolve-task-context.rb로 Git root·origin·branch·회사 publishing_policy를 확인하고 status·관련 diff·최근 commit·AGENTS·기여 규칙을 읽는다. 무관한 사용자 변경·비밀·인증·임시 파일을 stage하지 않는다.
2. scripts/resolve-publish-policy.rb에 workspace_type와 회사 merge_target/source를 전달한다. template 탐색 결과를 target/reviewer로 사용하지 않는다. 모드·저장소·포함/제외 파일을 보여 주되 이미 지정·확정한 값은 다시 묻지 않는다.
3. PR/MR에만 scripts/detect-provider.rb, 공식 template 탐색과 같은 source branch의 열린 게시물 조회를 수행한다. 기존 게시물은 재생성하지 않고 명시 변경 요청만 수정한다.
4. target은 사용자 지정 → 기존 PR/MR → 회사 프로젝트 예외 → 회사 공통 정책 → 저장소 설정 순서다. 회사 프로젝트는 원격 default를 사용하지 않는다. 개인·미등록만 마지막에 원격 default를 사용할 수 있다. 없으면 질문하고 dev/main을 추측하지 않는다.
5. PR/MR target은 git ls-remote --exit-code --heads origin refs/heads/<target>으로 확인한다. 대상 불일치·복수 후보·미확정 게시 값은 stage/게시 전에 해결한다.

## 실행과 결과

관련 파일만 stage하고 git diff --cached --stat, --check와 실제 diff를 확인한다. 저장소 규칙이 없으면 제목은 <type>: <subject>이며 type은 feat/fix/style/refactor/comment/docs/test/chore/rename/remove/build다. 임의 공동 작성자·기본 skip ci·ci.skip·no-verify·force push를 사용하지 않는다. 요청 모드에서만 확인한 remote branch로 push하며 upstream이 없을 때만 -u를 사용한다.

현재 승인 Workplan이 연결된 변경을 PR/MR로 게시할 때는 그 계획·실제 diff·기존 결과 설명도 대조한다. 설명에서 빠진 동작은 사용자와 리뷰어가 읽을 수 있게 보완하고, 미승인 설계가 있으면 [공통 인계의 문제 처리](../../references/implementation-handoff.md#구현-중-문제가-발견됐을-때)로 먼저 해소한다. MR 요청·테스트 성공을 미승인 설계의 승인으로 쓰지 않는다. Workplan 없는 변경에 사후 Workplan을 만들거나 과거 기록을 전역 검색하지 않으며 이 대조 때문에 테스트를 다시 실행하지 않는다.

PR/MR은 공식 template을 우선하고 fallback만 render-mr-body.rb와 lint-mr-body.rb로 만든다. 공식 양식은 --official로 검사한다. 생성 전 target·reviewer/assignee·제목·본문을 확인하고 target을 명시 옵션으로 전달한다. 미확정 target·전역 reviewer 추천을 자동 확정하지 않는다.

GitLab은 지정·저장소 설정으로 확정된 reviewer를 reviewer와 assignee에 넣는다. 성공 후 source·target·reviewer·assignee가 계획과 같음을 재조회한 뒤에만 select-reviewer.rb increment를 실행한다. GitHub reviewer를 GitLab 전역 파일에서 추정하지 않는다. 자동 병합·CI 취소를 하지 않는다.

선택 모드·commit·push·PR/MR URL·reviewer/계수·기존 검증·제외 파일·남은 작업을 보고한다. 수행하지 않은 작업을 완료로 표시하지 않는다.
