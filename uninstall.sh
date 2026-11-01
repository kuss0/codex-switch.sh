#!/usr/bin/env bash
set -euo pipefail

SHARE_DIR="$HOME/.local/share/ai-switch"
BIN_DIR="$HOME/.local/bin"
RC_FILE="$HOME/.bashrc"
PURGE_DATA=0

if [ "$#" -gt 0 ] && [ "$1" = "--purge-data" ]; then
  PURGE_DATA=1
elif [ "$#" -gt 0 ]; then
  printf 'Usage: %s [--purge-data]\n' "$(basename "$0")" >&2
  exit 2
fi

remove_hook() {
  local file="$1"
  [ -f "$file" ] || return 0
  sed -i \
    -e '/# >>> codex-switch >>>/,/# <<< codex-switch <<</d' \
    -e '/# >>> grok-switch >>>/,/# <<< grok-switch <<</d' \
    -e '/# >>> ai-switch >>>/,/# <<< ai-switch <<</d' \
    "$file"
}

remove_path() {
  local path="$1"
  [ -e "$path" ] || [ -L "$path" ] || return 0
  rm -f "$path"
}

remove_hook "$RC_FILE"
remove_path "$BIN_DIR/ai-switch"
remove_path "$BIN_DIR/codex-switch"
remove_path "$BIN_DIR/grok-switch"
remove_path "$SHARE_DIR/ai-switch.sh"
remove_path "$SHARE_DIR/codex-switch.sh"
remove_path "$SHARE_DIR/grok-switch.sh"
remove_path "$HOME/.codex/codex-switch.sh"
remove_path "$HOME/.grok/grok-switch.sh"

if [ "$PURGE_DATA" -eq 1 ]; then
  rm -rf "$SHARE_DIR" "$HOME/.grok"
  printf 'Removed switcher data under %s and %s\n' "$SHARE_DIR" "$HOME/.grok"
else
  rmdir "$SHARE_DIR" 2>/dev/null || true
  printf 'Preserved Codex profiles and tokens under %s\n' "$HOME/.codex"
  printf 'Use --purge-data to remove switcher data and legacy Grok data.\n'
fi

printf 'Codex switcher uninstalled. Start a new shell or run: source %s\n' "$RC_FILE"
