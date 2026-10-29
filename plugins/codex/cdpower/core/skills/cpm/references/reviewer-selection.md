# Reviewer Selection

GitLab `commit-push-mr`에서만 적용한다.

1. 사용자가 reviewer를 지정했으면 그 값을 확정한다.
2. 저장소 `.codex/reviewers.md` 또는 저장소 지침이 reviewer를 명시하면 그 범위에서 `scripts/select-reviewer.rb select <file>`로 후보를 계산하고 확정할 수 있다.
3. 저장소 설정이 없으면 `REVIEWERS_FILE`, 그다음 기존 `~/.claude/reviewers.md`에서 후보를 계산하되 전역 추천값으로만 제시하고 사용자 확인 전에는 지정하지 않는다.
4. `상태`에 `휴가`가 포함된 사람을 제외한다.
5. `배정 횟수`가 가장 적은 사람을 선택하고 동률이면 파일의 행 순서를 따른다.
6. 파일이 없거나 schema가 다르거나 배정 가능한 사람이 없으면 추측하지 않고 사용자에게 reviewer를 받는다.
7. 선택한 username, user_id, 출처와 확정 여부를 승인 패킷에 포함한다.
8. GitLab 신규 MR 생성 응답에서 reviewer 지정과 성공을 확인한 뒤에만 `scripts/select-reviewer.rb increment <file> <username>`으로 횟수를 1 증가시킨다.
9. MR 생성 실패, 기존 MR 재사용·수정, reviewer 미지정, GitHub PR에서는 횟수를 바꾸지 않는다.

Reviewer와 assignee는 기존 GitLab 흐름과 같이 같은 승인 사용자를 사용한다. 사용자가 다른 assignee를 명시하면 그 값을 우선한다.
