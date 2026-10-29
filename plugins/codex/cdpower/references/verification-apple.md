# Apple 검증 실행

선택 원칙은 [Verification Planning](verification-planning.md), 결과 판정은 [Verification Evidence](verification-evidence.md), 시각 적합성은 [UI Verification](ui-verification.md)이 소유한다. 이 문서는 Apple 도구 연결만 설명한다.

## 대상 확인

- workspace/project·target·scheme·destination·Xcode 버전, 기존 Swift Testing·XCTest·Snapshot 도구와 결과 저장 방식을 확인한다.
- Xcode MCP가 연결돼 있으면 호스트 AI가 Xcode의 현재 workspace·scheme·destination·진단을 직접 조회한다. 같은 정보를 찾기 위한 전체 프로젝트 순회나 추측 scheme·전체 빌드를 먼저 실행하지 않는다.
- 호스트 AI는 확인한 container·scheme·destination·test identifier를 `verification_context.hostCapabilities.targets`에 연결한다. 우리 MCP 서버가 다른 MCP 서버를 자동 호출한다고 가정하지 않는다.
- Xcode MCP가 없거나 필요한 실행을 제공하지 못할 때만 확인된 `xcodebuild -list -json`·`-showdestinations`로 대상을 좁힌다. 현재 서버의 자동 fallback 탐색은 등록 프로젝트 root의 `.xcworkspace`·`.xcodeproj`만 지원한다. 중첩 프로젝트는 해당 root를 등록하거나 호스트의 확인 결과를 사용한다.
- 신규 Swift 테스트는 지원 target에서 [Swift Testing Contract](swift-testing-contract.md)를 적용하고 기존 XCTest를 일괄 변환하지 않는다.

## 직접 실행

호스트 MCP 경로는 AI가 직접 영향 테스트를 실행한 뒤 `verification_run.hostResults[checkId]`에 targetId·destination·testIds·시작/종료 시각·exitCode·원본 출력·실제 summary를 연결한다. summary는 실제 도구 결과에서 추출하며 임의의 통과 요약을 만들지 않는다. 승인 전 결과나 다른 대상을 현재 실행으로 연결하지 않는다.

fallback은 선택한 scheme·destination의 `xcodebuild test`와 `-only-testing:<실제 식별자>`만 실행한다. 서버가 관리 데이터 아래 새 `.xcresult` 경로를 발급하며 `xcresulttool get test-results summary`로 실제 건수를 읽는다. 도구 버전이 이 summary API를 지원하지 않으면 로그의 BUILD SUCCEEDED로 대체 통과하지 않고 결과 해석 차단을 보고한다. build·clean·프로젝트 재생성·DerivedData 삭제를 자동 추가하지 않는다. 직접 테스트가 같은 configuration을 컴파일하면 별도 build를 생략한다.

커버리지가 필요한 실행은 시작 전에 현재 scheme/test plan의 수집 설정과 측정 대상을 확인한다. Xcode MCP의 테스트 건수만으로 커버리지가 수집됐다고 판단하지 않는다. 수집된 `.xcresult`가 제공되면 호스트 AI가 같은 실행의 결과에서 `xcrun xccov view --report --json <실제 결과 경로>` 등 로컬 도구가 지원하는 방법으로 수치를 읽어 [종류별 결과 보고](verification-evidence.md#검증-종류와-개별-확인-내용)에 연결한다. 결과에 없는 분기 커버리지는 미측정으로 밝히고 줄 커버리지로 대신하지 않는다. 설정 꺼짐·결과 없음·추출 실패를 구분하며 숫자 보고를 위해 앱 테스트를 반복하지 않는다. 이 지침은 기존 실행기의 자동 수집 구현을 뜻하지 않는다.

## 기기·화면 조건

- Simulator/실기기가 필요한 경계만 선택한다. BLE·권한 등의 Simulator 한계는 실기기 미검증으로 분리한다.
- Apple 제품 전체 화면의 기본 viewport는 기존 계약대로 iPhone 15의 `393×852 pt`, `@3x`(`1179×2556 px`, 19.5:9)다. 프로젝트가 다른 기기를 요구하면 그 값을 우선하고 단독 컴포넌트에 강제하지 않는다.
- locale·theme·Dynamic Type·OS·safe area·fixture를 영향 상태에 맞춰 고정한다. 같은 destination·DerivedData·출력 경로는 직렬 실행한다.
- Preview/Simulator screenshot은 렌더 보조 근거다. Golden 회귀나 Figma 원천 적합성·상호작용의 통과로 확대하지 않는다. 기존 UI gate의 독립 source 등록·candidate 비교·승격 authorization을 그대로 유지한다.

호스트 경로 연결과 parser 단위 테스트만으로 실제 iOS 앱 테스트를 실행했다고 보고하지 않는다. 실행한 프로젝트·도구·대상과 미실행 경로를 따로 기록한다.
