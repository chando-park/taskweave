# Serena Code Intelligence

코드의 선언·호출자·구현체·상속/프로토콜 관계를 판단해야 할 때 Serena의 symbol/LSP 결과를 우선 사용하는 계약이다. 단순히 Serena가 설치되어 있다는 기록이 아니라 실제 작업 세션에 필요한 도구가 노출됐는지를 편집 전에 확인한다.

## 적용 범위

다음 작업은 `semantic` 모드가 필수다.

- 새 프로젝트 기준선과 기능 흐름 추적
- 함수·타입·프로토콜·reducer·View의 책임이나 호출 경계를 조사하는 계획
- 둘 이상의 파일 또는 symbol에 걸친 기능·버그 수정
- caller, reference, implementation, override 또는 조립 지점을 바꾸는 구현
- 현재 메모의 대상 symbol이나 caller가 달라진 승인 후 correction

정확한 파일과 위치가 이미 확정된 문구·리소스 값·주석·문서·설정·단일 literal 교체는 `textual`로 분류할 수 있다. `textual`을 파일 크기나 작업이 귀찮다는 이유로 선택하지 않는다.

## 실행

1. 편집 전에 다음처럼 현재 세션의 실제 Serena 도구 노출을 검사한다.

   ```bash
   serena-preflight --mode semantic --repository <Git-root> \
     --available-tool initial_instructions \
     --available-tool activate_project \
     --available-tool get_symbols_overview \
     --available-tool find_symbol \
     --available-tool find_referencing_symbols
   ```

2. `semantic`이면 Serena의 `initial_instructions`를 읽고 정확한 Git root를 `activate_project`로 활성화한다.
3. 파일 전체를 먼저 읽지 않는다. `get_symbols_overview` 또는 `find_symbol(include_body: false)`로 구조를 좁히고 필요한 body만 읽는다.
4. 변경 symbol은 `find_referencing_symbols`로 caller를 확인한다. protocol·상속·다형성 경계가 있으면 `find_implementations` 또는 `find_declaration`도 사용한다.
5. 문자열·리소스·생성 코드처럼 LSP가 의미를 제공하지 않는 영역만 `rg`와 직접 파일 읽기로 보완한다. 텍스트 검색 결과를 symbol reference 결과처럼 표현하지 않는다.

## 새 프로젝트와 언어 설정

`serena-mcp` 실행기는 실제 프로젝트의 Git root에서 `.serena/project.yml`을 준비한 뒤 Serena를 시작한다. semantic preflight도 필요한 도구가 모두 노출되었을 때 같은 준비를 실행하므로, 다른 프로젝트로 전환할 때 해당 root의 preflight를 먼저 실행한다. textual preflight는 설정을 변경하지 않는다. 실행 중인 서버에서 preflight 없이 임의 프로젝트를 활성화하면 이 준비를 거치지 않는다.

새 프로젝트는 소스 확장자에서 Swift·Kotlin·Java 등 실제 언어를 여러 개 감지하고 `languages`와 `language_servers`를 함께 기록한다. vendor·build·Git ignored 파일과 symlink 하위는 감지에서 제외한다. 기존에 언어를 지정했다면 목록을 유지하고 누락된 호환 키만 보완한다. 두 목록이 충돌하거나 YAML이 손상되었으면 자동 덮어쓰기 대신 해당 설정을 확인하도록 안내한다. 지원 소스가 없는 폴더에는 언어를 추측하지 않는다.

플러그인 설치에서 `--with-serena`를 선택하면 기존 Serena를 재사용하고, 없으면 `uv`로 고정 버전을 설치한 뒤 선택한 호스트의 사용자 MCP를 등록한다. `uv` 자체와 JDK·Xcode·Android SDK는 설치하지 않는다. 실행기는 플러그인 cache 밖 관리 위치에 두므로 플러그인 실행 폴더를 제품 root로 사용하지 않는다. 설치·등록 후 실제 도구 반영은 새 호스트 세션에서 확인한다.

## 실패 처리

- `semantic`인데 Serena 도구가 현재 세션에 노출되지 않으면 `rg` 전수 검색으로 조용히 대체하지 않는다. 계획은 `ready`로, 구현은 검증 가능한 코드 경계가 확정된 것으로 보고하지 않고 Serena 연결 누락을 한 번 보고한다.
- 설치·서버 상태 진단에는 `serena project health-check <Git-root>`를 사용할 수 있다. 이 검사는 언어 서버를 시작하므로 매 작업마다 반복하지 않는다.
- Serena가 일부 언어·generated file을 분석하지 못하면 성공한 symbol 근거와 보완한 텍스트 근거를 구분한다. 해당 공백이 변경 경계를 바꾸지 않을 때만 계속한다.
- Serena memory는 제품 지식·Workplan·Product Memory의 정본이 아니다. 코드 탐색 캐시로만 취급한다.

## 결과

Workplan에 Serena 로그나 긴 검색 결과를 복사하지 않는다. 핵심 코드 항목에 실제 파일·symbol·caller와 `Observed (Serena)` 정도만 남긴다. 사전 검사 출력은 임시 실행 증거이며 새 Detail 문서를 만들지 않는다.
