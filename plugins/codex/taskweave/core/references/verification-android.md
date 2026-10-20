# Android 검증 실행

선택 원칙은 [Verification Planning](verification-planning.md), 결과 판정은 [Verification Evidence](verification-evidence.md), 시각 적합성은 [UI Verification](ui-verification.md)이 소유한다. 이 문서는 Android 도구 연결만 설명한다.

## 실제 프로젝트의 대상 확인

신뢰 확인한 프로젝트의 실행 가능한 `gradlew`, `gradle/wrapper/gradle-wrapper.properties`·jar와 settings/build 파일을 확인한다. 전역 `gradle`이나 임의 다운로드한 Wrapper를 대신 사용하지 않는다. Wrapper 실행은 프로젝트 스크립트를 실행하므로 탐색 후보를 실행 신뢰 확인으로 간주하지 않는다. AGP·Kotlin·JDK·Android SDK 호환성은 현재 프로젝트 선언과 설치 환경으로 확인하고 자동 업그레이드하지 않는다.

`verification_context`는 초기 대상 확인 때 Wrapper의 `--console=plain tasks --all` 출력에서 실제 모듈·task·variant를 읽는다. 이후 선택·실행은 저장된 context와 설정 digest를 재사용하며 매 실행마다 전체 task를 재탐색하지 않는다. 예시의 `:app`·`Debug`를 실제 대상으로 가정하지 않는다. 모듈·variant가 둘 이상이면 AI가 영향 범위를 선택해 사용자에게 보여 준다.

현재 실행기는 `test<Variant>UnitTest`·JVM `test`, `connected<Variant>AndroidTest`의 typed executor를 제공한다. 스크린샷은 실제 발견한 `verifyPaparazzi<Variant>`·`validate<Variant>ScreenshotTest`만 지원한다. `record`·`update`와 이름만 비슷한 임의 task는 실행하지 않는다. 일반적인 task 문자열이나 추가 Gradle 인자는 입력받지 않는다. 기존 테스트 소스에서 실제 식별자를 확인하지 못하면 임의로 추측해 실행하지 않는다.

스크린샷 task는 자동 선택하지 않는다. `requestedChecks`에 정확한 task ID·`testIds: []`·`taskScopeConfirmed: true`·모듈 build 아래 정확한 JUnit XML `resultPaths`를 고정해 task 전체 범위를 승인한다. 이 경로는 개별 필터를 지원하지 않으며 일부 테스트만 실행한 것으로 보고하지 않는다. 프로젝트가 JUnit 결과를 생성하지 않거나 정확한 출력 경로를 확인하지 못하면 HTML 존재만으로 통과시키지 않는다. 실제 fresh 결과가 모두 있어야 하며 기존 UI 원천·Golden gate는 별도다. [Paparazzi 공식 task](https://github.com/cashapp/paparazzi#tasks), [Compose Preview 검증 task](https://developer.android.com/studio/preview/compose-screenshot-testing#generate-test-report)를 따른다.

## 필요한 실행만 선택

| 경계 | 선택 |
| --- | --- |
| 계산·상태 전이·변환·coroutine/Flow | 기존 JVM 단위 테스트와 fixture |
| DB·Android API | 기존 Robolectric 또는 필요한 instrumented 통합 테스트 |
| 탭·이동·스크롤 | 기존 Compose·Espresso·UI Automator 영향 동작 테스트 |
| 색·간격·구조 | 기존 JVM/기기 스크린샷 도구로 영향 상태 렌더와 독립 원천 대조 |
| 권한·BLE·플랫폼 경계 | 필요한 API의 에뮬레이터/실기기. 에뮬레이터 한계는 별도 표시 |

JVM은 확인한 test task에만 `--tests <class.method>`를 전달한다. instrumented는 `-Pandroid.testInstrumentationRunnerArguments.class=<class#method>`를 사용하며 `--tests`를 재사용하지 않는다. 기기 검증이 필요할 때만 `includeDevices: true`로 기존 Android SDK의 `adb devices`를 조회하고 확인된 online device를 선택한다. 기기 생성·삭제·초기화는 하지 않는다.

시각 검증은 device·API·locale·크기·density·font scale·theme·fixture를 고정한다. Compose Preview Screenshot 도구도 프로젝트의 실제 AGP·환경 지원을 확인한 뒤 사용하며 자동 설치하지 않는다. JVM 스크린샷은 로직 테스트 성공과 별개로 보고하고, 현재 렌더를 정답으로 저장해 최초 적합성을 주장하지 않는다.

## 결과 파일과 한계

JVM은 선택 모듈의 `build/test-results/<task>` 아래 이번 실행 이후 XML만 읽는다. 기기는 `build/outputs/androidTest-results/connected/<variant>` 결과를 읽는다. 프로젝트가 다른 경로·managed device·커스텀 runner를 사용하면 별도 확인이 필요하며 오래된 다른 경로의 XML로 대체 통과하지 않는다. 실행 식별자와 선택한 class/method가 일치해야 한다.

NO-SOURCE·cache·skip·0건·device 오류·timeout은 공통 결과 원칙으로 판정한다. 현재 플러그인은 cache 재사용을 자동 통과시키지 않는다. 실행 출력은 합계 1 MiB로 제한하며 초과·timeout이면 자체 실행 그룹을 종료하고 차단으로 보고한다.

기존 JaCoCo/Kover XML은 선택 항목의 `coverage: {reportPath, format: jacoco|kover, scope, exclusions}`로 정확한 모듈 build 상대경로와 측정 범위를 승인한다. 새 coverage task·도구는 추가하지 않는다. 이번 실행 이후 생성된 JaCoCo 호환 XML의 report root `LINE`·`BRANCH` counter만 읽고 package/class counter와 중복 합산하지 않는다. 분자·분모·제외 범위·artifact hash를 별도로 보고하고 없는 branch는 미지원으로 남긴다. 오래됨·누락·다른 XML 형식은 미측정이며 요청한 측정을 완료했다고 보고하지 않는다. 출력 XML은 `inputPaths`에 넣지 않고 측정 원천·설정·의존성만 입력 hash에 포함한다. [JaCoCo counter 정의](https://www.jacoco.org/jacoco/trunk/doc/counters.html)를 적용한다.

parser fixture 테스트와 실제 Gradle/JVM 실행 검증은 구분한다. Android 지원 완료를 주장하기 전에 임시 샘플 또는 승인된 프로젝트에서 실제 JVM 테스트를 최소 한 번 실행·집계한다. JDK만 있고 Wrapper 배포·Android SDK가 없으면 설치 상태 확인이지 앱 테스트 성공이 아니다. 기기·UI·스크린샷은 실제 실행한 항목만 검증됐다고 보고한다.
