# Sidekick 설계 문서

> 상태: Draft  
> 작성일: 2026-06-12  
> 대상 환경: macOS, Ghostty 1.3.1, tmux 3.6a, Codex, Claude Code

## 1. 개요

Sidekick은 Codex 또는 Claude Code의 작업 완료 상태를 화면 위 캐릭터로 알려주고,
알림을 클릭하면 작업이 실행된 tmux pane으로 돌아가게 해주는 macOS 로컬 도구다.

명령어 wrapper는 사용하지 않는다. 각 에이전트가 제공하는 Hook을 통해 세션과 작업
이벤트를 수집하므로 기존 실행 습관을 바꾸지 않는 것이 핵심이다.

## 2. 목표

- Codex와 Claude Code의 한 턴 시작 및 완료를 감지한다.
- 화면 우하단에 항상 표시되는 캐릭터 위젯을 제공한다.
- 완료된 작업의 agent, 경로, prompt, 상태, 소요 시간을 보여준다.
- 알림을 클릭하면 기존 Ghostty 창을 활성화하고 해당 tmux pane으로 이동한다.
- Sidekick 장애가 Codex 또는 Claude Code 사용을 막지 않게 한다.

## 3. 비목표

MVP에서는 다음 기능을 구현하지 않는다.

- 에이전트 응답에 대한 별도 LLM 요약
- tmux를 사용하지 않는 터미널 세션 지원
- macOS 이외 운영체제 지원
- 원격 머신 또는 SSH 세션 간 이동
- 종료된 tmux pane 자동 복구
- Electron 또는 Tauri 기반 독립 애플리케이션

## 4. 설계 원칙

### Hook 기반

Codex와 Claude Code의 Hook stdin JSON을 받아 공통 이벤트 형식으로 정규화한다.
기존 Hook 설정을 교체하지 않고 같은 이벤트 배열에 Sidekick Hook을 추가한다.

### Fail-open

Sidekick Hook은 항상 짧게 실행되고, 내부 오류가 발생해도 exit code `0`으로 끝난다.
오류는 별도 로그에 남기되 prompt 제출이나 응답 완료를 차단하지 않는다.

### 로컬 우선

이벤트와 prompt는 로컬 파일에만 저장한다. 네트워크 요청이나 외부 분석 서비스는
사용하지 않는다.

### append-only

Hook이 직접 공유 상태 JSON을 수정하지 않고 한 줄 JSON 이벤트만 추가한다.
여러 세션이 동시에 완료되어도 상태 파일 덮어쓰기 경쟁을 피하기 위함이다.

## 5. 시스템 구성

```text
Codex hooks.json                  Claude settings.json
       |                                  |
       +-------- Sidekick Hook -----------+
                         |
                 stdin JSON 정규화
                         |
             tmux pane/client 정보 보강
                         |
                 events.jsonl append
                         |
               Hammerspoon file watcher
                         |
         floating character + task popover
                         |
                  사용자가 항목 클릭
                         |
            Ghostty focus + tmux pane 이동
```

### 구성 요소

| 구성 요소 | 역할 |
|---|---|
| Hook adapter | Codex/Claude payload를 공통 이벤트로 변환 |
| Event store | `events.jsonl`에 이벤트를 append |
| State reducer | 이벤트를 세션별 최신 상태로 축약 |
| Hammerspoon UI | 캐릭터, badge, 최근 완료 작업 목록 표시 |
| tmux navigator | 저장된 client와 pane으로 이동 |

## 6. 디렉터리 구조

개발 소스와 실행 데이터를 분리한다.

```text
# 개발 소스
<workspace>/sidekick/
  DESIGN.md
  README.md
  assets/
    character.png
  hooks/
    sidekick-event.sh
  lib/
    normalize-event.jq
    tmux-context.sh
  hammerspoon/
    init.lua
    sidekick.lua
  scripts/
    install.sh
    uninstall.sh
    emit-fixture.sh
  fixtures/
    codex/
    claude/

# 설치 및 실행 데이터
~/.sidekick/
  assets/
    character.png
  bin/
    sidekick-event
  state/
    events.jsonl
  logs/
    hook-errors.log
    ui-errors.log
```

Hook 설정에는 workspace 경로 대신 설치 후 고정되는
`~/.sidekick/bin/sidekick-event`를 등록한다.

## 7. 이벤트 모델

### 수집 이벤트

| Hook | Sidekick 이벤트 | 의미 |
|---|---|---|
| `SessionStart` | `session.started` | 에이전트 세션 등록 |
| `UserPromptSubmit` | `turn.started` | 새 작업 턴 시작 |
| `Stop` | `turn.completed` | 정상 응답 완료 |
| `StopFailure` | `turn.failed` | API 오류 등 비정상 완료 |
| `SessionEnd` | `session.ended` | 세션 정리 |

MVP는 Codex의 `SessionStart`, `UserPromptSubmit`, `Stop`을 먼저 연결한다.
Claude Code 지원 시 동일 adapter에 agent 식별만 추가한다.

`SessionEnd`와 `StopFailure`는 각 제품의 실제 Hook 지원 여부와 payload fixture를
검증한 뒤 활성화한다. 지원하지 않는 경우 세션 만료 시간과 다음 이벤트로 보정한다.

### 공통 이벤트 schema

```json
{
  "schemaVersion": 1,
  "eventId": "uuid",
  "eventType": "turn.completed",
  "occurredAt": "2026-06-12T07:21:00.000Z",
  "agent": "codex",
  "sessionId": "session-id",
  "turnId": "turn-id-or-derived-id",
  "cwd": "/Users/me/project",
  "repo": "project",
  "branch": "feature/example",
  "promptPreview": "사용자 prompt 앞부분",
  "summaryPreview": "최종 assistant 응답 앞부분",
  "status": "completed",
  "durationMs": 12400,
  "tmux": {
    "paneId": "%12",
    "sessionName": "work",
    "windowId": "@3",
    "windowIndex": "2",
    "paneIndex": "1",
    "clientTty": "/dev/ttys004",
    "socketPath": "/private/tmp/tmux-501/default"
  },
  "source": {
    "hookEventName": "Stop"
  }
}
```

### 필드 처리

- `sessionId`: Hook payload 값을 우선 사용한다.
- `turnId`: payload에 없으면 `sessionId + turn sequence`로 생성한다.
- `promptPreview`: 최대 300자만 저장하며 줄바꿈을 공백으로 치환한다.
- `summaryPreview`: payload에 최종 assistant 메시지가 있을 때만 최대 300자 저장한다.
- `repo`: `git rev-parse --show-toplevel`의 basename, 실패하면 cwd basename을 사용한다.
- `branch`: Git 저장소가 아니거나 detached HEAD면 `null`을 허용한다.
- `durationMs`: 같은 `turnId`의 시작과 완료 시각 차이로 계산한다.
- 원본 Hook payload 전체는 저장하지 않는다.

## 8. 상태 전이

```text
session.started
      |
      v
turn.started -----> turn.failed
      |
      v
turn.completed
      |
      +------> 다음 turn.started
      |
      v
session.ended
```

UI는 `events.jsonl`을 읽어 `sessionId`와 `turnId` 기준 최신 상태를 메모리에서
재구성한다. 별도 `sessions.json`을 진실 원본으로 두지 않는다.

### 읽지 않은 완료 작업

- `turn.completed` 또는 `turn.failed` 수신 시 unread로 등록한다.
- 해당 항목을 클릭하면 read로 변경한다.
- 캐릭터 badge에는 unread 개수를 표시한다.
- 현재 포커스된 pane에서 완료된 작업도 기록하지만, MVP에서는 badge를 동일하게 표시한다.
- 이벤트 보존 기간은 7일, UI 표시 개수는 최근 20개로 제한한다.

## 9. tmux 위치 캡처

Hook 프로세스가 물려받은 `TMUX_PANE`을 기준으로 위치를 캡처한다.

```bash
tmux display-message -p -t "$TMUX_PANE" \
  '#{pane_id}|#{session_name}|#{window_id}|#{window_index}|#{pane_index}|#{client_tty}'
```

저장 우선순위는 다음과 같다.

1. `pane_id`: window index가 바뀌어도 이동 가능한 주 식별자
2. `client_tty`: 여러 tmux client 중 기존 Ghostty client 식별
3. `session_name`, `window_id`: pane 이동 실패 시 진단 및 fallback 정보

`TMUX_PANE`이 없으면 이벤트는 저장하되 `tmux: null`로 기록하고 이동 버튼을
비활성화한다.

## 10. 터미널 이동

사용자가 완료 항목을 클릭하면 다음 순서로 처리한다.

1. `hs.application.launchOrFocus("Ghostty")`로 Ghostty를 활성화한다.
2. 저장된 `paneId`가 존재하는지 확인한다.
3. 저장된 `clientTty`가 아직 연결되어 있으면 해당 client를 target pane으로 전환한다.
4. client 전환 후 target pane을 명시적으로 선택한다.
5. pane 또는 client가 없으면 UI에 이동 실패 사유를 표시한다.

개념 명령은 다음과 같다.

```bash
tmux display-message -p -t "$pane_id" '#{pane_id}'
tmux switch-client -c "$client_tty" -t "$pane_id"
tmux select-pane -t "$pane_id"
```

실제 구현에서는 tmux 버전에 따른 target 해석을 fixture로 검증한다.

### MVP fallback

- pane이 닫힘: `이 작업의 pane이 종료됐어요` 표시
- client가 끊김: session 이름을 보여주고 자동 이동하지 않음
- Ghostty가 종료됨: Ghostty만 실행하고 task를 unread 상태로 유지

새 Ghostty 창에서 자동 `tmux attach`하는 기능은 후속 버전으로 미룬다.

## 11. UI 설계

Hammerspoon의 `hs.canvas`로 투명 floating widget을 만든다.

### 기본 상태

- 위치: 현재 주 모니터 우하단, 화면 가장자리에서 24px 여백
- 크기: 72x72px
- 이미지: `assets/character.png`
- 모든 Space에서 표시
- 일반 창보다 위에 표시하되 fullscreen 작업을 과도하게 방해하지 않는 level 사용
- 드래그로 위치 변경 가능, 위치는 로컬 설정에 저장

### 상태 표현

| 상태 | 표현 |
|---|---|
| idle | 캐릭터만 표시 |
| running | 작은 pulse 또는 파란 점 |
| completed | unread 숫자 badge |
| failed | 붉은 badge |
| 이동 불가 | 목록 항목에 `pane closed` 표시 |

### 클릭 동작

- 캐릭터 클릭: 최근 작업 popover 열기/닫기
- 작업 항목 클릭: 해당 tmux pane 이동 후 read 처리
- badge 클릭: popover 열기
- 우클릭: Reload, Open logs, Quit 메뉴

### 작업 항목

```text
[Codex] krokerdile · feature/example
설계 문서 먼저 만들어봐줘
완료 · 18초 전 · 42.3초
```

prompt와 assistant 응답은 tooltip 또는 확장 영역에서만 일부 표시한다.

## 12. Hammerspoon 연동

현재 머신에는 Hammerspoon이 설치되어 있지 않다. 구현 후 실제 UI 실행 전 설치와
macOS Accessibility 권한 승인이 필요하다.

설치 시 `~/.hammerspoon/init.lua` 전체를 교체하지 않고 다음 한 줄만 추가한다.

```lua
require("sidekick").start({
  home = os.getenv("HOME") .. "/.sidekick"
})
```

Sidekick 모듈은 `~/.hammerspoon/sidekick.lua`에 설치한다.

이벤트 감지는 `hs.pathwatcher`와 짧은 debounce를 사용한다. JSONL 마지막 줄이 쓰이는
도중 읽힐 수 있으므로 파싱 실패한 마지막 줄은 다음 file event에서 재시도한다.

## 13. Hook 설치

### Codex

현재 `~/.codex/hooks.json`에는 다른 Hook이 이미 등록되어 있다. 각 이벤트의 기존
배열을 유지한 채 다음 command Hook을 추가한다.

```json
{
  "type": "command",
  "command": "/Users/mac_al03235502/.sidekick/bin/sidekick-event codex",
  "timeout": 3
}
```

대상 이벤트:

- `SessionStart`
- `UserPromptSubmit`
- `Stop`

Codex의 Hook trust hash가 변경될 수 있으므로 설치 후 새 Hook 승인이 필요한지
확인한다.

### Claude Code

`~/.claude/settings.json`에도 기존 Hook을 보존하며 같은 command를 추가한다.
첫 단계에서는 `agent` 인자만 `claude`로 전달한다.

Claude Code는 `StopFailure`와 `SessionEnd`도 지원 가능하지만, MVP의 Codex 흐름을
검증한 다음 연결한다.

### stdin과 stdout

- adapter는 stdin 전체를 한 번 읽는다.
- 정상 동작 시 stdout에 아무것도 출력하지 않는다.
- Hook 응답 제어 JSON을 반환하지 않는다.
- 오류 메시지는 `~/.sidekick/logs/hook-errors.log`에만 기록한다.
- 어떤 오류에서도 에이전트 실행을 막지 않는다.

## 14. 동시성 및 내구성

- 이벤트 한 줄은 4KB 이하로 제한한다.
- 한 줄 JSON을 한 번의 append 작업으로 기록한다.
- `eventId`로 UI 중복 처리를 방지한다.
- `sessionId + eventType + turnId`가 같으면 reducer에서 중복 이벤트로 간주한다.
- 비정상 종료로 마지막 JSONL 줄이 깨지면 해당 줄만 무시하고 로그에 기록한다.
- 7일이 지난 이벤트 정리는 UI 시작 시 하루 한 번 수행한다.
- 정리 작업은 새 파일 작성 후 atomic rename으로 교체한다.

## 15. 개인정보 및 보안

- prompt와 assistant preview는 각각 최대 300자만 저장한다.
- 환경 변수, Hook 원본 payload, transcript 전체는 저장하지 않는다.
- API key, token 형태의 문자열은 기본 redaction pattern으로 마스킹한다.
- 상태 파일 권한은 사용자 전용 `0600`, 디렉터리는 `0700`으로 생성한다.
- shell 명령에 prompt, cwd, branch를 문자열 보간하지 않는다.
- tmux target은 허용된 형식인지 검증한 뒤 인자로 전달한다.

## 16. 로깅

```text
~/.sidekick/logs/hook-errors.log
~/.sidekick/logs/ui-errors.log
```

로그에는 timestamp, component, event type, session ID 일부, 오류 코드만 기록한다.
prompt 본문과 assistant 응답은 오류 로그에 남기지 않는다.

로그 파일은 각각 1MB를 넘으면 한 세대만 rotate한다.

## 17. 검증 계획

### Hook adapter

- Codex `SessionStart`, `UserPromptSubmit`, `Stop` fixture 정규화
- 필드가 누락된 payload 처리
- Git 저장소가 아닌 cwd 처리
- tmux 밖에서 실행된 Hook 처리
- 민감 정보 redaction
- 동시에 여러 이벤트를 append해도 JSONL이 유효한지 확인

### tmux navigator

- 기존 pane으로 정상 이동
- window index 변경 후 pane ID로 이동
- pane 종료 시 실패 상태 반환
- client 종료 시 fallback 상태 반환
- 두 Ghostty/tmux client가 연결된 경우 저장된 client만 전환

### UI

- 빈 이벤트 파일에서 idle 표시
- 완료 이벤트 수신 시 badge 증가
- 중복 이벤트 수신 시 badge 중복 증가 방지
- 항목 클릭 시 read 처리
- 잘린 마지막 JSONL 줄 복구
- 멀티 모니터에서 위치 저장 및 복원

### 통합 시나리오

1. Ghostty의 tmux pane A에서 Codex를 실행한다.
2. 다른 pane B 또는 다른 앱으로 이동한다.
3. Codex prompt를 완료한다.
4. Sidekick badge와 작업 항목이 표시되는지 확인한다.
5. 항목을 클릭한다.
6. Ghostty가 활성화되고 pane A가 선택되는지 확인한다.

## 18. 구현 단계

### Phase 0: 문서와 fixture

- 설계 확정
- 실제 Codex Hook payload fixture 수집
- tmux client/pane 이동 명령 검증

완료 기준: fixture에 민감 정보가 없고 공통 schema가 확정된다.

### Phase 1: Headless Codex MVP

- Hook adapter
- JSONL event store
- Codex Hook 연결
- CLI fixture emitter
- tmux navigator

완료 기준: UI 없이도 Codex 완료 이벤트가 저장되고 명령으로 원래 pane 이동이 된다.

### Phase 2: Hammerspoon UI

- Hammerspoon 설치
- 캐릭터 floating widget
- badge와 최근 작업 목록
- 클릭 이동

완료 기준: 다른 앱을 사용 중에도 완료 상태를 확인하고 클릭 한 번으로 돌아간다.

### Phase 3: Claude Code 지원

- Claude payload fixture
- Claude Hook 연결
- `StopFailure`, `SessionEnd` 처리

완료 기준: Codex와 Claude 작업이 같은 목록에서 구분되어 표시된다.

### Phase 4: 사용성 개선

- 현재 pane에서 완료되면 badge 생략 옵션
- 말풍선
- 자동 attach fallback
- 캐릭터 및 위치 설정
- 메뉴바 설정 화면

## 19. 현재 확인된 환경

| 항목 | 상태 |
|---|---|
| macOS | 사용 중 |
| Ghostty | 1.3.1 설치됨 |
| tmux | 3.6a 설치됨 |
| Hammerspoon | 미설치 |
| Codex Hook | `SessionStart`, `UserPromptSubmit`, `Stop` 사용 중 |
| Claude Hook | `SessionStart`, `UserPromptSubmit`, `Stop`, `StopFailure` 사용 중 |
| 캐릭터 asset | `sidekick/assets/character.png` 준비됨 |

## 20. 남은 결정

구현 전에 다음 항목만 최종 결정하면 된다.

1. 캐릭터 기본 크기: 제안 `72x72px`
2. 기본 위치: 제안 `주 모니터 우하단`
3. prompt preview 저장 여부: 제안 `300자 + 민감 정보 redaction`
4. 현재 보고 있는 pane의 완료 알림도 badge로 표시할지 여부
5. Hammerspoon을 Homebrew로 설치할지 수동 설치할지
