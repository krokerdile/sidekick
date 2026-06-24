# Sidekick 성능 개선 — As-Is / To-Be

> 관련 브랜치: `perf/sidekick-event-pipeline` (base: `main`)
> 관련 문서: `DESIGN.md`(설계), `docs/sidekick-worklog.md`(UI 작업 기록)

## 배경

Hammerspoon으로 만든 Sidekick이 전반적으로 무겁다는(지연, 로딩) 체감이 있어 Electron/Tauri 마이그레이션을 검토했다. 코드 분석 결과 원인은 Hammerspoon 프레임워크 자체가 아니라 `hammerspoon/sidekick.lua`의 이벤트 처리 파이프라인 설계에 있었다. 마이그레이션 전에 먼저 이 파이프라인을 고치는 쪽(트랙 A)으로 진행했다.

## As-Is — 무거움의 원인 3가지

### 1. 메인 스레드를 블록하는 동기 tmux 호출

`reduceTasks()`가 호출될 때마다 `activePaneIds()`가 `hs.execute("tmux list-panes -a ...", true)`를 **동기 실행**했다. Hammerspoon의 단일 메인 스레드를 블록해 드래그/클릭 반응이 늦어지는 직접적인 원인이었다.

```lua
-- as-is
local function activePaneIds()
  local output, success = hs.execute(command, true)  -- 동기, 블로킹
  ...
end

local function reduceTasks(events)
  local currentPanes = activePaneIds()  -- 매 reduce마다 블로킹 호출
  ...
end
```

### 2. 전체 파일 재파싱 + retention 미구현

`readEvents()`가 append-only로 계속 커지는 `events.jsonl` **전체를 매번 한 줄씩 재파싱**했다. DESIGN.md 14절에 "7일 지난 이벤트 정리"가 설계되어 있었지만 실제 구현은 없었다(`prune`/`expire`/`rename` 류 코드 부재 확인). 파일이 무한히 커지므로 재파싱 비용도 시간이 갈수록 늘어났다.

### 3. 폴링과 파일 와처의 중복 트리거

`hs.pathwatcher`(파일 변경 시 0.1초 뒤 재로드)와 `hs.timer.doEvery(2, reloadEvents)`(2초마다 강제 재로드)가 **동시에** 위 1·2번의 무거운 경로를 호출했다. 변경이 잦으면 같은 작업이 중복으로 실행됐다.

## To-Be — 적용한 변경

### 1. 동기 tmux 호출 → 비동기 캐시

`hs.task`로 `tmux list-panes`를 비동기 실행하고 결과를 모듈 레벨 `activePanes` 캐시에 저장한다. `reduceTasks()`는 캐시만 참조하므로 더 이상 메인 스레드를 블록하지 않는다.

```lua
-- to-be
local function refreshActivePanes()
  if paneRefreshTask then return end
  paneRefreshTask = hs.task.new("/bin/sh", function(exitCode, stdout, _)
    paneRefreshTask = nil
    if exitCode ~= 0 then return end
    activePanes = parsedPaneIds(stdout)
    tasks = reduceTasks(lastEvents)
    refreshCanvas()
  end, { "-c", command })
  paneRefreshTask:start()
end

reduceTasks = function(events)
  local currentPanes = activePanes  -- 캐시 참조, 블로킹 없음
  ...
end
```

### 2. retention 구현 — 7일 지난 이벤트 정리

시작 시 `pruneOldEvents()`를 실행해 `occurredAt`이 7일을 초과한 라인을 제거하고, 임시 파일에 쓴 뒤 `os.rename`으로 atomic 교체한다. 파일이 작게 유지되므로 전체 재파싱 비용도 줄어든다.

### 3. 폴링/와처 경로 분리

- `pathwatcher` 콜백에 디바운스를 추가해, 짧은 시간에 연속 변경이 와도 직전 타이머를 취소하고 마지막 한 번만 `reloadEvents()`를 실행한다.
- 2초마다 전체 `reloadEvents()`를 강제 실행하던 `paneTimer`는 제거하고, **pane 캐시 갱신(`refreshActivePanes`)만 5초 주기**로 분리했다. 파일 변경 감지는 `pathwatcher`가 전담한다.

```lua
-- to-be
watcher = hs.pathwatcher.new(config.home .. "/state", function()
  if reloadDebounceTimer then reloadDebounceTimer:stop() end
  reloadDebounceTimer = hs.timer.doAfter(0.1, function()
    reloadDebounceTimer = nil
    reloadEvents()
  end)
end)
paneTimer = hs.timer.doEvery(5, refreshActivePanes)  -- 더 이상 reloadEvents 전체 재실행 안 함
```

## 효과 요약

| 항목 | As-Is | To-Be |
|---|---|---|
| pane 조회 | 매 reduce마다 동기 `hs.execute` (메인 스레드 블록) | 5초 주기 비동기 `hs.task` + 캐시 참조 |
| 파일 재파싱 | 2초마다 전체 `events.jsonl` 무조건 재파싱, 파일 무한 증가 | 파일 변경 시(디바운스)만 재파싱 + 7일 retention으로 파일 크기 상한 |
| 중복 트리거 | pathwatcher + 2초 폴링이 같은 무거운 reduce를 동시 실행 | 파일 변경(디바운스)과 pane 캐시 갱신(5초) 역할 분리, 중복 없음 |

## 남은 항목 (보류/다음 단계)

- **증분 파싱**: 파일 offset을 기억해 append된 부분만 읽는 방식. 지금은 retention으로 파일 크기를 누른 상태라 효과가 줄었지만, 이벤트 양이 많아지면 다음 단계로 고려.
- **드래그 폴링 완화(100Hz → 60Hz)**: 영향이 크지 않고, `mouseMove` 콜백을 의도적으로 제거한 과거 이력(커밋 `0eea5ae`)이 있어 보류.
- **Electron/Tauri 마이그레이션**: 트랙 A로 체감이 충분히 개선되면 재평가. 마이그레이션 사유가 "성능"이 아니라 "독립 배포/리치 UI"로 좁혀질 때 진행. Electron은 상시 메모리 사용량(Chromium 상주, ~200MB+)이 늘어나 "가벼움" 목적과는 상충하므로, 가더라도 Tauri 또는 네이티브(SwiftUI/AppKit)를 우선 검토.

## 검증

- `luajit -e "loadfile('hammerspoon/sidekick.lua')"` 로 문법 확인 — OK
- `node test/run.js` — 통과 (단, hook CLI 레이어만 커버하며 Hammerspoon UI 레이어는 미커버)
- 미검증: 실제 Hammerspoon Console에서 드래그/클릭/badge/멀티모니터 동작 — Hammerspoon 런타임에서 직접 확인 필요
