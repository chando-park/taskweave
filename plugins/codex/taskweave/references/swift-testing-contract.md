# Swift Testing Contract

- 신규 Swift 단위·통합 테스트는 타깃이 지원하면 `import Testing`, `@Test`, `#expect`, `#require`를 기본으로 사용한다.
- 기존 테스트를 보강할 때 같은 타깃에서 Swift Testing을 사용할 수 있으면 신규 테스트도 Swift Testing으로 작성할 수 있다. fixture·실행 경계가 불명확하면 기존 관용구를 유지한다.
- XCUITest UI 테스트, XCTest 전용 성능·attachment·lifecycle 기능, Objective-C 테스트와 지원하지 않는 도구 체인은 XCTest를 유지한다.
- 현재 작업과 무관한 XCTest 전체 migration은 수행하지 않는다.
- 프레임워크와 무관하게 실제 실행 건수와 결과를 확인한다.

## 테스트 표시 제목

- 새 Swift Testing 테스트의 `@Test("...")`와 `@Suite("...")`처럼 사람이 읽는 표시 제목은 한글로 작성한다. 조건과 기대 결과가 드러나는 짧은 문장으로 쓴다.
- Swift 함수·타입·파일 이름과 테스트 실행 식별자는 저장소의 코드 명명 관례를 따른다. 제목을 한글로 쓰기 위해 식별자를 한글로 바꾸지 않는다.
- 저장소가 테스트 표시 제목의 언어를 별도로 지정하면 그 규칙을 우선한다. 제목이 없는 기존 테스트나 작업 범위 밖 테스트를 일괄 변경하지 않는다.

```swift
@Suite("날짜 선택")
struct DateSelectionTests {
    @Test("취소하면 기존 선택 날짜를 유지한다")
    func cancelKeepsSelectedDate() { /* ... */ }
}
```

## Xcode 실행 도구

- Xcode MCP는 테스트 프레임워크가 아니라 로컬 Xcode의 프로젝트 문맥·진단·실행 기능을 사용하는 adapter다. 테스트 소스는 이 도구를 import하거나 의존하지 않는다.
- Xcode MCP가 연결되어 있으면 열린 workspace·scheme·destination과 현재 진단을 먼저 확인하고, 가장 작은 영향 테스트를 실행하는 데 사용한다. 이미 Xcode가 가진 문맥을 같은 세션에서 shell로 다시 탐색하지 않는다.
- Xcode MCP를 사용할 수 없거나 필요한 실행 기능이 실패하면 정확한 `xcodebuild` 명령으로 대체하고 이유를 결과에 남긴다. 한 경로가 유효하게 통과했다면 같은 configuration의 다른 경로를 관성적으로 반복하지 않는다.
- Xcode MCP 연결, 컴파일, 테스트, Preview, Snapshot과 UI 원천 적합성은 각각 별도 판정이다. 테스트 성공은 실제 실행 식별자·건수·실패 수로 확인한다.

## 첫 실행 전 확인

- 같은 test target의 기존 테스트 하나를 읽어 `Testing` 또는 `XCTest`, fixture, actor isolation과 실행 식별자 관용구를 확인한다.
- 새 import와 matcher·CasePath·support module을 사용하면 test target의 manifest가 해당 모듈을 직접 link하는지 확인한다. production target의 전이 의존성만으로 test compile을 가정하지 않는다.
- 테스트를 위해 production `State`·`Action`에 불필요한 `Equatable` 등 새 계약을 추가하지 않는다. 해당 프레임워크의 assertion 방식이나 기존 target helper로 검증할 수 있는지 먼저 확인한다.
- 첫 명령은 영향 test 하나를 직접 식별해 실행한다. discovery·compile·link가 확인된 뒤에만 관련 묶음으로 넓힌다.
