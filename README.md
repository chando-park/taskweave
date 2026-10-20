# Taskweave

Codex와 Claude Code에서 사용하는 개인 작업 플러그인입니다. 요청 파악 → 필요한 계획·승인 → 수정 → 원문·요구사항과 대조 → 피드백 반영의 공통 흐름을 사용하고, 작업 종류에 맞는 규칙만 읽습니다. 코드뿐 아니라 요약·대본 등에도 사용할 수 있습니다. 모든 작업에 Workplan이나 앱 테스트를 강제하지 않습니다.

이 저장소는 **직접 운영하는 GitHub 플러그인 장터**입니다. OpenAI·Anthropic 공식 기본 장터에 입점했다는 뜻이 아닙니다. 주소를 한 번 등록한 후 `taskweave`를 설치합니다. 별도 서버나 ZIP 다운로드는 필요하지 않습니다.

## 준비

Node.js 22 이상, Ruby, Git, 사용할 호스트의 CLI가 필요합니다. 로그인은 각 호스트에서 완료합니다. 기본 패키지의 MCP 의존성은 포함되어 있으므로 별도 `npm install`은 필요하지 않습니다. 현재 배포·설치 확인 환경은 macOS입니다. Windows·Linux에서의 실제 호스트 설치는 아직 검증하지 않았습니다.

## Codex 설치

터미널에서 실행합니다.

```sh
codex plugin marketplace add https://github.com/chando-park/taskweave.git
codex plugin add taskweave@taskweave-marketplace
```

새 대화에서 `$taskweave:setup`을 요청합니다. 일부 클라이언트 버전은 스킬 선택기에서 `taskweave`로 검색해 선택해야 할 수 있습니다.

## Claude Code 설치

터미널에서 실행합니다.

```sh
claude plugin marketplace add https://github.com/chando-park/taskweave.git --scope user
claude plugin install taskweave@taskweave-marketplace --scope user
```

새 대화에서 `/taskweave:setup`을 요청합니다.

## 처음 사용할 때

- 일반 요약·대본 수정은 프로젝트 등록 없이 사용할 수 있습니다.
- 프로젝트·작업 기록을 관리하려면 setup에서 코드가 담긴 폴더와 기록 보관 위치를 지정합니다. 기존 Workplans·Product Memory는 원래 위치를 연결하고 자동 이동·변환하지 않습니다.
- Serena·Figma·Jira는 호스트에 이미 연결된 도구를 재사용합니다. 필요한 연결·로그인은 해당 호스트의 공식 기능으로 진행합니다. Taskweave MCP가 다른 MCP를 자동 호출하거나 토큰을 대신 발급하지 않습니다.
- 기존 AGENTS.md·CLAUDE.md·직접 설치한 스킬을 자동 삭제·교체하지 않습니다. 스킬은 `taskweave:` 이름으로 선택합니다. 모든 대화의 전역 지침까지 전환하려면 기존 지침을 보존하는 별도 연결 작업이 필요합니다.
- 기존 `taskweave@my-ai-toolbox` 로컬 설치와 이번 `taskweave@taskweave-marketplace` 원격 설치를 동시에 켜면 중복 노출될 수 있습니다. 새 설치를 확인한 뒤 이전 Taskweave만 선택적으로 비활성화하고 다른 플러그인·스킬·설정은 유지합니다.

## 포함된 기능

개인 스킬 14개와 setup 1개, 연결된 공통 규칙, 로컬 stdio MCP를 제공합니다. MCP의 기본 도구는 다음 세 가지입니다.

| 도구 | 하는 일 |
| --- | --- |
| `context_read` | 등록한 작업공간의 필요한 자료 읽기 |
| `task_current` | 현재 작업을 제한된 단서로 찾기 |
| `record_save` | 중복 요청·동시 저장 충돌을 확인하며 기록 저장 |

실제 코드 편집·테스트·외부 서비스 호출은 AI가 호스트의 도구로 수행합니다. MCP는 문서 형식이나 승인 기록을 심사해 작업 시작을 허가하는 프로그램이 아닙니다. 실제 테스트 실패·자료 부족·사용자 권한은 별도로 존중합니다.

## 업데이트

Codex에서는 다음 명령으로 장터 목록을 갱신한 뒤 호스트의 플러그인 관리에서 설치 버전을 확인합니다. 목록 갱신만으로 실행 중 세션의 버전이 바뀌었다고 판단하지 않습니다.

```sh
codex plugin marketplace upgrade taskweave-marketplace
```

Claude Code:

```sh
claude plugin marketplace update taskweave-marketplace
claude plugin update taskweave@taskweave-marketplace --scope user
```

업데이트 뒤에는 새 대화에서 확인합니다. 작업 기록과 기존 연결은 업데이트 대상이 아닙니다.

## 데이터와 보안

MCP는 사용자 컴퓨터에서 실행합니다. 기록은 설정한 로컬·외부 작업공간 위치에 저장합니다. 조회한 내용은 AI에게 도구 결과로 전달되므로, 사용하는 Codex·Claude와 연결 서비스의 데이터 처리 정책도 적용됩니다. 로컬 실행이라는 이유로 자료가 컴퓨터 밖으로 절대 전달되지 않는다고 보장하지 않습니다.

인증값을 채팅·Workplan·Product Memory에 넣지 않습니다. 공개 패키지에는 개인 작업 기록·회사 전용 스킬·제품 코드·인증 파일을 포함하지 않습니다. 기본 설정 경로는 호환을 위해 `~/.config/ai-workflow/settings.json`, 관리 데이터는 `~/.local/share/ai-workflow/`를 사용합니다. 플러그인 캐시와 장기 기록은 별도입니다.

문제는 [GitHub Issues](https://github.com/chando-park/taskweave/issues)에 남겨 주세요. 공개 이슈에 회사 자료·개인정보·토큰·비밀 로그를 붙이지 않습니다.

## 배포 정보와 사용 허락

현재 버전은 0.3.0입니다. 원본 커밋은 `93a1f50aac3a7c40155df8976380cbc5768d8b88`이며 배포 패키지만 이 저장소에 포함합니다. 다른 작업의 미커밋 변경과 원본 저장소의 전체 이력은 포함하지 않습니다. `plugins/codex/taskweave`와 `plugins/claude/taskweave`가 각 호스트의 실제 패키지입니다.

별도의 오픈소스 라이선스는 아직 지정하지 않았습니다. 저장소 공개가 코드의 자유로운 재배포·수정 권한을 부여한다는 뜻은 아닙니다. 외부 의존성의 고지와 라이선스는 각 패키지의 `THIRD_PARTY_NOTICES.md` 및 포함된 원본 LICENSE를 따릅니다.
