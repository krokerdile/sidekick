#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="${SIDEKICK_HOME:-$HOME/.sidekick}"
HAMMERSPOON_DIR="$HOME/.hammerspoon"

if [[ "${1:-}" == "--dry-run" ]]; then
  printf 'Would install Sidekick from %s to %s\n' "$SOURCE_DIR" "$TARGET_DIR"
  printf 'Would install Hammerspoon module to %s/sidekick.lua\n' "$HAMMERSPOON_DIR"
  HOME="${HOME}" SIDEKICK_HOME="$TARGET_DIR" node "$SOURCE_DIR/scripts/configure.js"
  exit 0
fi

mkdir -p "$TARGET_DIR/bin" "$TARGET_DIR/assets" "$TARGET_DIR/state" "$TARGET_DIR/logs"
mkdir -p "$HAMMERSPOON_DIR"
install -m 0755 "$SOURCE_DIR/bin/sidekick" "$TARGET_DIR/bin/sidekick"
install -m 0755 "$SOURCE_DIR/scripts/configure.js" "$TARGET_DIR/bin/sidekick-profiles"
install -m 0644 "$SOURCE_DIR/assets/character.png" "$TARGET_DIR/assets/character.png"
install -m 0644 "$SOURCE_DIR/assets/character-widget.png" "$TARGET_DIR/assets/character-widget.png"
install -m 0644 "$SOURCE_DIR/assets/character-widget-v2.png" "$TARGET_DIR/assets/character-widget-v2.png"
install -m 0644 "$SOURCE_DIR/hammerspoon/sidekick.lua" "$HAMMERSPOON_DIR/sidekick.lua"
install -m 0644 "$SOURCE_DIR/hammerspoon/init.lua" "$HAMMERSPOON_DIR/sidekick-init.lua"
chmod 0700 "$TARGET_DIR" "$TARGET_DIR/state" "$TARGET_DIR/logs"
HOME="${HOME}" SIDEKICK_HOME="$TARGET_DIR" node "$SOURCE_DIR/scripts/configure.js" --apply

printf 'Installed Sidekick runtime to %s\n' "$TARGET_DIR"
printf 'Configured Codex, Claude, and Hammerspoon integration.\n'
