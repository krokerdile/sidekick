# Sidekick 작업 기록

## 작업 계획

목표: 지금까지 진행한 Sidekick 작업을 기능 단위로 분해해, 후속 수정과 회고에 바로 쓸 수 있는 작업 기록 문서를 남긴다.

### 작업 단위

1. 프로필/설치 자동화
   - Codex `.codex*` 프로필 자동 탐색
   - Claude `.claude*` 프로필 자동 탐색
   - `sidekick-profiles` 명령 정리

2. 작업 상태/목록 모델
   - 세션 단위 최신 작업 1개만 유지
   - 닫힌 tmux pane 제거
   - `turn.started`, `turn.completed`, `turn.failed` 상태 표시

3. 말풍선/캐릭터 UI
   - 작업 중/완료 말풍선 표시
   - 이미지 crop 문제 수정
   - 말풍선 위치와 표시 시간 조정

4. 목록/옵션 UI
   - native popup 제거
   - 작업 목록과 하단 옵션 행을 custom canvas로 교체
   - 외부 클릭 시 닫힘 처리

5. 클릭/드래그/이동
   - 캐릭터 클릭 지연 제거
   - 드래그 반응 지연 최소화
   - tmux focus 경로 검증

### 산출물

- `findings.md`: 각 작업에서 확인한 원인과 결정사항
- `progress.md`: 실제 수정/검증 이력

## 발견사항

### 1. 프로필 관리

- Codex는 `.codex`, `.codex-enterprise`, `.codex-per`, `.codex-pro`, `.codex-trial` 5개가 실제 프로필이었다.
- Claude는 `.claude`, `.claude-personal` 2개가 실제 프로필이었다.
- 기존에는 프로필별 hook 연결이 일부만 되어 있었고, 자동 탐색 범위를 확장해야 했다.

### 2. 작업 상태 모델

- 목록이 `turn.completed`만 기준이면 현재 진행 중인 작업이 보이지 않았다.
- 세션당 최신 작업만 남기도록 바꾸면서, 1/2/3번 turn이 쌓이는 대신 최신 turn 하나만 노출되게 했다.
- 닫힌 tmux pane은 목록에서 제거해야 UI가 현실 상태와 맞았다.

### 3. 말풍선

- 말풍선은 `turn.started`, `turn.completed`, `turn.failed`를 모두 반응 대상으로 써야 했다.
- 처음에는 이벤트 수집과 실제 UI 표시를 혼동해서 `turn.started`가 보일 거라고 잘못 판단했다.
- bubble duration과 배치 위치는 실제 frame 기준으로 봐야 했고, 이미지 자체의 투명 여백도 고려해야 했다.

### 4. 목록/옵션 UI

- macOS native popup은 좌표를 추정해서 제어하기가 불안정했다.
- `popupMenu()`는 좌상단 좌표를 받지만, 실제 폭/높이가 콘텐츠에 따라 흔들려 겹침이 잦았다.
- 해결 방향은 고정 frame의 custom canvas로 바꾸는 것이었다.
- 목록 하단에 옵션 행을 두는 구조가 가장 단순하고 이해하기 쉬웠다.

### 5. 클릭/드래그

- 캐릭터 드래그 지연의 핵심은 mouseMove를 즉시 반영하지 않고 polling timer에만 의존한 점이었다.
- Accessibility 권한이 꺼져 있는 상태에서는 전역 eventtap 방식이 불안정하거나 실패할 수 있었다.
- 캐릭터 클릭 지연은 polling으로 확정하던 구조 때문에 생겼고, mouseUp에서 즉시 열도록 바꿔야 했다.

## 진행 로그

### 2026-06-13

#### 설치/프로필

- Sidekick runtime을 `~/.sidekick`에 설치했다.
- Codex 5개 프로필과 Claude 2개 프로필의 hook 연결을 자동화했다.
- `sidekick-profiles`로 프로필 상태를 점검할 수 있게 정리했다.

#### 작업 목록

- 목록은 세션당 최신 turn 하나만 보이도록 바꿨다.
- 닫힌 tmux pane은 목록에서 제거되도록 동기화했다.
- `turn.started`, `turn.completed`, `turn.failed` 상태를 구분 표시했다.

#### 캐릭터/말풍선

- 캐릭터 이미지 crop 문제를 수정하고 말풍선 표시를 복구했다.
- 말풍선은 작업 중과 완료/실패 시점 모두 뜨도록 바꿨다.

#### UI

- 작업 목록과 옵션 메뉴를 custom canvas로 교체했다.
- 목록 하단에 `옵션` 행을 추가했다.
- 외부 클릭 시 닫히도록 dismiss 영역을 추가했다.
- 더블클릭 분기는 제거하고, 한 번 클릭으로 목록을 여는 방식으로 단순화했다.

#### 클릭/드래그

- 캐릭터 클릭의 반응 지연을 줄이기 위해 mouseUp 즉시 목록을 열도록 수정했다.
- 드래그는 canvas 내부 mouseMove와 짧은 polling을 함께 사용하도록 재구성했다.
- tmux focus 경로는 실제 `%36` pane으로 이동하는지 확인했다.

