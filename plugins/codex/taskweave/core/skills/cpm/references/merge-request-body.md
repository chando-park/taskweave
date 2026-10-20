# Merge Request Body

`scripts/find-template.rb <repository> <provider>`가 반환한 저장소 공식 PR/MR template이 있으면 그 구조를 우선한다. 없으면 `scripts/render-mr-body.rb <input.json> <output.md>`로 다음 fallback 섹션을 생성한다.

- `## 📋 개요`
- `## ✅ 변경 사항`
- `## 📁 변경된 파일`
- `## 📋 코드 리뷰 결과`
  - 변경 사항 개요
  - Critical Issues
  - Warnings
  - Suggestions
  - Positive Points
  - 코드 품질·아키텍처·보안 평가와 판정
- `## 🧪 테스트`
- `## ⚠️ 남은 위험`

입력 JSON은 `summary`, `changes`, `files`, `review`, `tests`, `remaining_risks`를 사용한다. 테스트에는 정확한 명령과 `실행 건수·통과·실패·건너뜀` 요약만 넣고 전체 runner 로그를 넣지 않는다.

fallback 본문은 `scripts/lint-mr-body.rb <output.md>`, 공식 template 기반 본문은 `scripts/lint-mr-body.rb --official <output.md>`를 반드시 실행하고 파일을 직접 읽어 검토한다. `--official`은 저장소 고유 섹션을 허용하지만 나머지 안전 검사는 동일하다. 다음 상태에서는 게시하지 않는다.

- literal `\\n`이 남음
- 백틱 심볼이나 값이 비어 있음
- 필수 섹션 누락
- 원시 `Test Suite`·`Test Case` 로그 포함
- 본문 12KB 초과

본문을 shell 문자열로 조립하거나 백틱·`$()`이 포함된 Markdown을 command argument에 직접 삽입하지 않는다. 검증된 description file을 GitHub/GitLab CLI의 body/description-file 옵션으로 전달한다.
