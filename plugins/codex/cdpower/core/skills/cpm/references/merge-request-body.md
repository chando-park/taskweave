# Merge Request Body

`scripts/find-template.rb <repository> <provider>`가 반환한 저장소 공식 PR/MR template이 있으면 그 구조를 우선한다. 없으면 `scripts/render-mr-body.rb <input.json> <output.md>`로 다음 fallback 섹션을 생성한다.

## 여러 커밋의 MR 본문

MR은 하나만 만든다. `git log --reverse --topo-order --format='%H %s' <target>..HEAD`로 대상 브랜치에 없는 커밋을 오래된 순서로 확인한다. 2개 이상이면 변경 사항·파일·코드 리뷰·최종 의견을 커밋별로 작성한다. 제목은 식별용이며 리뷰 근거는 각 커밋의 실제 diff다. 일반 커밋은 `git show --format= --patch <sha>`, merge commit은 `git diff <sha>^1 <sha>`로 확인하고, 마지막에 `<target>...HEAD`의 최종 diff로 커밋 간 연결·상충·회귀를 검토한다. 후속 커밋에서 해소된 지적은 해당 사실을 표시하고 최종 상태의 미해결 문제와 구분한다. 지적은 해당 커밋 SHA의 파일·라인에 연결한다.

공통의 `🎯 해결하려는 문제`와 `🛠️ 접근 방법` 뒤에 아래 구역을 넣고, 커밋 블록을 실제 개수만큼 반복한다. 커밋마다 Critical·Warning·Suggestion·Positive를 남기며 발견 사항이 없으면 `없음`으로 적는다. 품질 점수는 넣지 않는다.

```markdown
## 📝 커밋별 변경 사항·코드 리뷰

### 1. <커밋 SHA> — <커밋 제목>

#### ✅ 변경 사항
- [해당 커밋의 실제 변경]

#### 📁 변경된 파일
- [해당 커밋의 파일과 변경 내용]

#### 📋 코드 리뷰 결과
##### 변경 사항 개요
[영향 모듈·변경 규모]
##### 🔴 Critical Issues
[해당 SHA의 파일:라인과 설명 또는 없음]
##### 🟡 Warnings
[설명 또는 없음]
##### 🟢 Suggestions
[설명 또는 없음]
##### ✅ Positive Points
[설명 또는 없음]

#### 📊 종합 평가
- 최종 의견: APPROVE / REQUEST_CHANGES / COMMENT

## 🔎 커밋 간 연계 검토
- [최종 diff에서 확인한 커밋 간 연결·충돌·회귀·후속 해결 여부]
- 최종 의견: APPROVE / REQUEST_CHANGES / COMMENT

## 🧪 테스트
측정 기준: 커밋 `<실제 측정한 SHA>`
- [실행 모듈]: N% (covered/executable줄) 또는 수집 실패 (사유)
```

테스트 섹션은 기존 실행 조건을 유지한다. 측정 커밋이 다르면 커밋별로 커버리지를 구분해 적는다. 최종 HEAD에서 얻은 수치를 이전 커밋 결과로 복사하거나, 커밋별 표를 채우기 위해 승인 없이 테스트를 재실행하지 않는다. 테스트를 실행했지만 측정 revision을 확인할 수 없으면 그 증거를 특정 커밋의 커버리지로 보고하지 않고 확인을 요청한다.

## 단일 커밋의 fallback 본문

- `## 📋 개요`
- `## ✅ 변경 사항`
- `## 📁 변경된 파일`
- `## 📋 코드 리뷰 결과`
  - 변경 사항 개요
  - Critical Issues
  - Warnings
  - Suggestions
  - Positive Points
  - 점수 없이 최종 의견만 기재 (`APPROVE` / `REQUEST_CHANGES` / `COMMENT`)
- `## 🧪 테스트` — 실행 건수가 1 이상인 모듈이 있을 때만 포함
- `## ⚠️ 남은 위험`

복수 커밋 입력은 `problem`, `approach`, `commits`, `integration_review`, `tests`, `remaining_risks`를 사용한다. `commits`는 순서대로 전달한 2개 이상의 객체이며 각 객체는 `sha`, `title`, `changes`, `files`, `review`를 가진다. `review`는 단일 본문의 것과 같은 `overview`, `critical`, `warnings`, `suggestions`, `positive`, `verdict`를 사용한다. `integration_review`는 `findings` 배열과 `verdict`로 최종 연계 검토를 전달한다. 실행한 `tests` 항목에는 본문의 커밋 SHA와 같은 `revision`을 반드시 넣는다. 생성기는 측정 커밋이 없거나 본문과 무관한 커버리지 입력을 거절한다. 공식 template을 사용하면 저장소의 구조를 보존하며 커밋별 내용을 해당 구역에 배치한다.

단일 커밋의 입력 JSON은 `summary`, `changes`, `files`, `review`, `tests`, `remaining_risks`를 사용한다. `review.scores`는 요구하거나 출력하지 않으며 최종 의견은 `review.verdict`로 전달한다.

`tests`는 생략하거나 빈 배열로 둘 수 있다. 각 실행 모듈은 `module`, `executed_count`, 결과 번들에서 읽은 `covered_lines`·`executable_lines`를 전달한다. 수집 실패는 줄 수 대신 `coverage_error`에 사유를 전달한다. 실행 건수가 없거나 0인 항목은 본문에서 제외한다. 테스트 건너뜀·미실행·0건 실행이면 테스트 섹션 전체를 생략하고, 실행 모듈만 `- 모듈: N% (covered/executable줄)` 또는 `수집 실패 (사유)`로 쓴다. 테스트 타깃·미실행 모듈·외부 의존성의 커버리지, 실행 명령·로그·테스트 목록을 MR 테스트 섹션에 넣지 않는다. 기존 `command`·`result`만 있는 입력은 실행 건수나 커버리지를 추정하지 않고 섹션에서 제외한다.

실제 명령과 실행·통과·실패·건너뜀 결과, 미실행 사유는 사용자 보고와 기존 검증 기록에 계속 남긴다. MR 양식에서 테스트 섹션을 생략하는 것과 검증 결과 보고를 생략하는 것은 다르다.

fallback 본문은 `scripts/lint-mr-body.rb <output.md>`, 공식 template 기반 본문은 `scripts/lint-mr-body.rb --official <output.md>`를 반드시 실행하고 파일을 직접 읽어 검토한다. `--official`은 저장소 고유 섹션을 허용하지만 나머지 안전 검사는 동일하다. 다음 상태에서는 게시하지 않는다.

- literal `\\n`이 남음
- 백틱 심볼이나 값이 비어 있음
- 필수 섹션 누락
- 원시 `Test Suite`·`Test Case` 로그 포함
- 본문 12KB 초과

본문을 shell 문자열로 조립하거나 백틱·`$()`이 포함된 Markdown을 command argument에 직접 삽입하지 않는다. 검증된 description file을 GitHub/GitLab CLI의 body/description-file 옵션으로 전달한다.
