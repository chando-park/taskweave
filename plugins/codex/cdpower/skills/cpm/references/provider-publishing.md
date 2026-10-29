# Provider Publishing

`scripts/detect-provider.rb <origin>` 결과가 `github` 또는 `gitlab`일 때만 게시한다. 알 수 없는 provider는 중단한다.

## GitLab

현재 `glab`이 지원하는 명령을 `--help`로 확인한다. 열린 MR 중복 조회의 기준 명령은 다음과 같다.

```bash
glab mr list --source-branch <source-branch> --output json
```

구버전 문서의 지원되지 않는 `--state opened`를 사용하지 않는다. 결과 JSON에서 현재 source branch의 열린 MR을 확인한다. 기존 MR이 있으면 중복 생성하지 않고 URL과 target을 사용한다. 사용자가 수정을 명시한 경우에만 기존 MR의 target·reviewer 변경을 별도 확인한다.

## GitHub

```bash
gh pr list --head <source-branch> --state open --json number,url
```

열린 PR이 없을 때만 `gh pr create --body-file <file>`을 실행한다. 기존 PR이 있으면 재사용한다. reviewer는 GitHub 저장소 설정이나 사용자 지정이 있을 때만 추가한다.

## Target 결정

template은 본문 형식일 뿐 target 근거가 아니다. 다음 순서로 독립적으로 결정한다.

1. 사용자가 이번 요청에서 지정한 target
2. 같은 source branch에 이미 열린 PR/MR의 target
3. 등록된 회사 프로젝트의 프로젝트별 게시 예외
4. 등록된 회사 프로젝트의 회사 공통 게시 정책
5. 저장소 `AGENTS.md`, 기여 문서 또는 `.codex/cpm.yaml`의 명시적 설정
6. 개인·미등록 저장소에 한해 provider가 반환한 원격 저장소 default branch
7. 확인 불가 시 사용자 질문

등록된 회사 프로젝트는 원격 default branch를 병합 정책으로 해석하지 않는다. `dev`, `main`, 현재 branch 이름을 관습만으로 선택하지 않는다.
확정 target이 원격에 실제 존재하는지 `git ls-remote --exit-code --heads`로 확인하며, 없으면 provider default로 대체하지 않는다.

## 공통

- PR/MR 생성 명령에는 확정된 target을 명시적으로 전달하고, URL과 source·target branch가 요청과 일치하는지 생성 후 재조회한다.
- 신규 GitLab MR의 target·reviewer·assignee가 계획과 모두 일치하기 전에는 reviewer 배정 횟수를 갱신하거나 완료로 보고하지 않는다.
- 기존 PR/MR은 재생성하지 않는다. target·reviewer 변경은 사용자가 명시한 경우에만 수정한다.
- 생성 성공 전 reviewer 횟수를 갱신하지 않는다.
- 병합, force push, CI 취소는 자동 수행하지 않는다.
