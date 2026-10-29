# Swift 코드 작성 규칙

Swift를 새로 작성하거나 수정하기 **직전** 읽고 영향 영역에 적용한다. 최종 diff에서도 확인한다. 저장소의 더 구체적인 formatter·동시성 계약을 우선하며 무관한 파일을 일괄 변환하지 않는다.

## 세로 간격과 체인

- 같은 수준의 타입·프로퍼티·초기화·함수·계산 프로퍼티 선언 사이에 빈 줄 하나를 둔다. 닫는 `}` 다음에 다른 독립 선언이나 문장이 오면 한 줄 띄운다. `ReducerBuilder` 안의 `BindingReducer()`와 각 독립 `Scope`도 한 줄씩 띄운다.
- 연속된 `case`, `else`·`catch`, 하나의 표현식으로 이어지는 클로저·modifier에는 기계적으로 빈 줄을 넣지 않는다. 기존 파일 전체를 이 규칙만으로 재포맷하지 않는다.
- 둘 이상의 메서드 연속 호출은 시작 표현식 다음 줄부터 각 호출을 `.`으로 시작하는 별도 줄에 둔다. 예: `HomeEntryQueueFeature()` 다음 줄에 `.reduce(...)`, 그 다음 줄에 `.map(...)`. 호출 사이에 빈 줄은 넣지 않는다.
- 빌드·테스트 통과를 스타일 확인으로 대신하지 않는다.

## 동시성

- 새로 작성하거나 수정하는 비동기 로직은 `async/await`, `@MainActor`·actor, `async let`·task group, `AsyncSequence` 등 Swift 동시성을 기본으로 한다. 단순 지연·백그라운드 실행·메인 UI 전달을 위해 `DispatchQueue`, `DispatchGroup`, semaphore 또는 중첩 completion callback을 새로 도입하지 않는다.
- 동기 진입점에서 `Task`가 필요하면 소유자와 취소 시점을 정한다. `Task.detached`는 격리·수명 요구가 명확할 때만 사용한다. UI 상태는 임의 main queue dispatch 대신 `@MainActor` 격리나 `MainActor.run`으로 접근한다.
- SDK·프레임워크가 특정 queue나 callback을 요구하는 경계는 기존 계약을 유지한다. adapter에 격리하고 Swift 동시성으로 바로 표현할 수 없는 이유, 취소·수명·순서 보장을 코드와 검증에 남긴다.

## Preview와 테스트

- SwiftUI `View`를 새로 만들거나 UI·동작을 바꾸면 대표 상태 `#Preview`를 작성하거나 유지한다. 지원하지 않는 toolchain만 `PreviewProvider`와 이유를 기록한다.
- 신규 Swift 단위·통합 테스트는 target이 지원하면 Swift Testing을 기본으로 한다. 테스트 작성/수정 직전 [Swift Testing 계약](swift-testing-contract.md)을 읽고 표시 제목은 한글로 쓴다. 무관한 XCTest를 일괄 변환하지 않는다.
