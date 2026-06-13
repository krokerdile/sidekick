# Sidekick — Copilot Instructions

Sidekick은 Codex / Claude Code의 작업 완료를 macOS 화면 위 캐릭터 위젯으로 알려주는 로컬 도구다.

## 아키텍처

```
Agent Hook (Codex / Claude Code)
  → bin/sidekick (Node.js CLI)
      → ~/.sidekick/state/events.jsonl (append-only 이벤트)
          → Hammerspoon file watcher
              → hammerspoon/sidekick.lua (floating UI)
                  → tmux pane 이동
```

## 핵심 원칙

- **Fail-open**: Hook 오류가 에이전트 실행을 막으면 안 된다. 항상 exit 0.
- **append-only**: events.jsonl에 직접 쓰지 않고 한 줄 JSON만 추가한다.
- **로컬 우선**: 네트워크 요청이나 외부 서비스 없음. 모든 상태는 로컬 파일.

## 주요 구성 요소

| 파일 | 역할 |
|---|---|
| `bin/sidekick` | Hook adapter, event store, tmux navigator CLI |
| `hammerspoon/sidekick.lua` | Hammerspoon 캐릭터 위젯, 말풍선, 작업 목록 |
| `hammerspoon/init.lua` | Hammerspoon 진입점 |
| `scripts/install.sh` | `~/.sidekick` 런타임 설치 |
| `scripts/configure.js` | Codex / Claude 프로필 Hook 자동 연결 |

## 코드 리뷰 시 확인 사항

- `bin/sidekick`의 Hook handler: stdin 파싱 실패해도 exit 0인지 확인
- tmux pane ID / client TTY 검증: 허용된 형식(`%\d+`, `/dev/ttys\d+`)만 통과하는지
- events.jsonl append: 4KB 초과 이벤트 거부, 민감 정보 redaction 동작
- Hammerspoon Lua: canvas 생성/삭제 누수 없는지, mouseCallback nil 체크
- `configure.js`: 기존 Hook 보존(덮어쓰기 금지), idempotent 동작
