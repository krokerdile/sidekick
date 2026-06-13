# Sidekick

Codex와 Claude Code 작업 완료를 캐릭터 위젯으로 표시하고, 클릭하면 작업하던
Ghostty tmux pane으로 이동하는 macOS 로컬 도구다.

## 현재 MVP

- Hook payload를 공통 JSONL 이벤트로 저장
- prompt와 assistant 응답 preview 저장 및 기본 secret redaction
- 완료 작업 unread 상태 관리
- tmux pane ID와 Ghostty client TTY 캡처
- CLI로 해당 tmux pane 이동
- Hammerspoon floating character와 최근 작업 목록
- 캐릭터 드래그 이동과 마지막 위치 저장
- 완료/실패 말풍선과 클릭 시 해당 pane 이동
- 캐릭터를 가리지 않는 작업 메뉴 자동 배치
- 제목·본문·이동 안내가 분리된 고대비 말풍선
- 우클릭 설정 메뉴에서 말풍선 on/off와 위치 초기화

위젯은 원본 `assets/character.png`를 보존한다. 화면 표시에는 전체 몸이 보이도록
새로 생성하고 배경을 투명 처리한 `assets/character-widget-v2.png`를 사용한다.

## 로컬 검증

```bash
chmod +x bin/sidekick scripts/install.sh test/run.js
node test/run.js
scripts/install.sh --dry-run
```

개발 경로에서 fixture를 직접 실행하려면:

```bash
export SIDEKICK_HOME="$PWD/.runtime"
bin/sidekick hook codex < fixtures/session-start.json
bin/sidekick hook codex < fixtures/prompt-submit.json
bin/sidekick hook codex < fixtures/stop.json
bin/sidekick list
```

## 설치 전제

- macOS
- Ghostty
- tmux
- Node.js
- Hammerspoon

`scripts/install.sh`는 기존 설정을 보존한 채 다음 항목을 idempotent하게 추가한다.

- `~/.sidekick` runtime
- `~/.hammerspoon/sidekick.lua`
- `~/.hammerspoon/init.lua`의 Sidekick require
- 현재 `CODEX_HOME` 및 존재하는 `~/.codex*` 프로필의 세 가지 lifecycle Hook
- 현재 `CLAUDE_CONFIG_DIR` 및 존재하는 `~/.claude*` 프로필의 세 가지 lifecycle Hook

설정 파일을 변경할 때 기존 파일은 `.sidekick-backup` suffix로 백업한다.
실제 설치와 Hook 등록은 홈 디렉터리 설정을 수정하므로 별도 승인 후 진행한다.
현재 설계와 설치 위치는 [DESIGN.md](./DESIGN.md)를 참고한다.

## 에이전트 프로필 관리

`config.toml`이 있는 `~/.codex*`와 `settings.json`이 있는 `~/.claude*` 디렉터리를
자동 탐색한다.

```bash
# 프로필별 연결 상태 확인
~/.sidekick/bin/sidekick-profiles --profiles-only

# 누락된 모든 프로필에 Sidekick Hook 연결
~/.sidekick/bin/sidekick-profiles --profiles-only --apply
```
