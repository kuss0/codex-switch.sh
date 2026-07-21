#!/usr/bin/env bash
set -euo pipefail

# Install Codex + Grok CLIs and the unified ai-switch profile switcher.

REPO_RAW_BASE="${AI_SWITCH_RAW_BASE:-https://raw.githubusercontent.com/kuss0/codex-switch.sh/main}"
SHARE_DIR="${AI_SWITCH_SHARE_DIR:-$HOME/.local/share/ai-switch}"
BIN_DIR="${AI_SWITCH_BIN_DIR:-$HOME/.local/bin}"
INSTALL_PATH="${AI_SWITCH_INSTALL_PATH:-$SHARE_DIR/ai-switch.sh}"

msg() {
  printf '%s\n' "$*"
}

can_prompt() {
  [ -t 0 ] && return 0
  [ -e /dev/tty ] || return 1
  { :; } 2>/dev/null </dev/tty >/dev/tty
}

prompt() {
  local prompt_text var_name
  prompt_text="$1"
  var_name="$2"
  local -n target="$var_name"

  if [ -t 0 ]; then
    read -r -p "$prompt_text" target
  else
    # shellcheck disable=SC2034
    read -r -p "$prompt_text" target </dev/tty
  fi
}

have() {
  command -v "$1" >/dev/null 2>&1
}

as_root() {
  if [ "$(id -u)" = "0" ]; then
    "$@"
  elif have sudo; then
    sudo "$@"
  else
    return 1
  fi
}

download_to_stdout() {
  local url
  url="$1"

  if have curl; then
    curl -fsSL "$url"
  elif have wget; then
    wget -qO- "$url"
  else
    msg "curl or wget is required to download: $url" >&2
    return 1
  fi
}

download_to_file() {
  local url dest
  url="$1"
  dest="$2"
  download_to_stdout "$url" > "$dest"
}

install_packages() {
  if have apt-get; then
    as_root apt-get update
    as_root apt-get install -y ca-certificates curl wget unzip zip
  elif have dnf; then
    as_root dnf install -y ca-certificates curl wget unzip zip
  elif have yum; then
    as_root yum install -y ca-certificates curl wget unzip zip
  elif have apk; then
    as_root apk add --no-cache ca-certificates curl wget unzip zip
  else
    msg "No supported package manager found. Skipping system dependency install."
  fi
}

load_fnm() {
  export PATH="$HOME/.local/share/fnm:$PATH"
  if have fnm; then
    eval "$(fnm env --shell bash)"
  fi
}

install_node() {
  if ! have fnm; then
    msg "Installing fnm..."
    download_to_stdout "https://fnm.vercel.app/install" | bash
  fi

  load_fnm

  if ! have fnm; then
    msg "fnm was not found after install." >&2
    return 1
  fi

  msg "Installing Node.js 20..."
  fnm install 20
  fnm default 20
  fnm use 20
  load_fnm
}

install_clis() {
  if ! have npm; then
    msg "npm was not found after Node.js setup." >&2
    return 1
  fi

  msg "Installing Codex CLI..."
  npm install -g @openai/codex

  msg "Installing Grok CLI..."
  npm install -g @xai-official/grok
}

install_switcher() {
  local script_source script_dir local_dir tmp name
  script_source="${BASH_SOURCE[0]:-}"
  local_dir=""

  if [ -n "$script_source" ] && [ -f "$script_source" ]; then
    case "$script_source" in
      /dev/*|/proc/*) ;;
      *)
        script_dir="$(cd "$(dirname "$script_source")" >/dev/null 2>&1 && pwd -P)"
        if [ -f "$script_dir/ai-switch.sh" ] && [ -f "$script_dir/codex-switch.sh" ] && [ -f "$script_dir/grok-switch.sh" ]; then
          local_dir="$script_dir"
        fi
        ;;
    esac
  fi

  mkdir -p "$SHARE_DIR" "$BIN_DIR" "$HOME/.codex" "$HOME/.grok"
  chmod 700 "$HOME/.codex" "$HOME/.grok" 2>/dev/null || true

  for name in ai-switch.sh codex-switch.sh grok-switch.sh; do
    tmp="$(mktemp)"
    if [ -n "$local_dir" ] && [ -f "$local_dir/$name" ]; then
      cp "$local_dir/$name" "$tmp"
    else
      download_to_file "$REPO_RAW_BASE/$name" "$tmp"
    fi
    install -m 700 "$tmp" "$SHARE_DIR/$name"
    rm -f "$tmp"
  done

  ln -sf "$SHARE_DIR/ai-switch.sh" "$BIN_DIR/ai-switch" 2>/dev/null || true
  ln -sf "$SHARE_DIR/codex-switch.sh" "$BIN_DIR/codex-switch" 2>/dev/null || true
  ln -sf "$SHARE_DIR/grok-switch.sh" "$BIN_DIR/grok-switch" 2>/dev/null || true

  # Keep legacy paths working
  ln -sf "$SHARE_DIR/codex-switch.sh" "$HOME/.codex/codex-switch.sh" 2>/dev/null || true
  ln -sf "$SHARE_DIR/grok-switch.sh" "$HOME/.grok/grok-switch.sh" 2>/dev/null || true

  "$SHARE_DIR/ai-switch.sh" init-config
  AI_SWITCH_SCRIPT_PATH="$INSTALL_PATH" "$SHARE_DIR/ai-switch.sh" install-shell "$HOME/.bashrc"
}

maybe_create_profiles() {
  local answer name

  if [ "${AI_SWITCH_SKIP_PROFILE:-0}" = "1" ]; then
    return 0
  fi

  # Non-interactive codex profile
  if [ -n "${CODEX_SWITCH_PROFILE:-}" ]; then
    "$SHARE_DIR/codex-switch.sh" add "$CODEX_SWITCH_PROFILE"
    "$SHARE_DIR/codex-switch.sh" use "$CODEX_SWITCH_PROFILE"
  fi

  # Non-interactive grok profile
  if [ -n "${GROK_SWITCH_PROFILE:-}" ]; then
    "$SHARE_DIR/grok-switch.sh" add "$GROK_SWITCH_PROFILE"
    "$SHARE_DIR/grok-switch.sh" use "$GROK_SWITCH_PROFILE"
  fi

  if [ -n "${CODEX_SWITCH_PROFILE:-}" ] || [ -n "${GROK_SWITCH_PROFILE:-}" ]; then
    return 0
  fi

  if ! can_prompt; then
    return 0
  fi

  prompt "Create first Codex profile now? [Y/n]: " answer
  case "$answer" in
    n|N|no|NO|No) ;;
    *)
      prompt "Codex profile name [default]: " name
      name="${name:-default}"
      "$SHARE_DIR/codex-switch.sh" add "$name"
      "$SHARE_DIR/codex-switch.sh" use "$name"
      ;;
  esac

  prompt "Create first Grok profile now? [Y/n]: " answer
  case "$answer" in
    n|N|no|NO|No) ;;
    *)
      prompt "Grok profile name [default]: " name
      name="${name:-default}"
      "$SHARE_DIR/grok-switch.sh" add "$name"
      "$SHARE_DIR/grok-switch.sh" use "$name"
      ;;
  esac
}

main() {
  msg "Installing dependencies..."
  install_packages || msg "Dependency install skipped or partially failed. Continuing..."

  install_node
  install_clis
  install_switcher
  maybe_create_profiles

  msg ""
  msg "ai-switch installed (Codex + Grok)."
  msg "Open a new shell, or run: source ~/.bashrc"
  msg ""
  msg "Codex:  cx  cxe  cxadd  cxuse  cxlist  cxwhich  cxrm"
  msg "Grok:   gx  gxe  gxadd  gxuse  gxlist  gxwhich  gxrm"
  msg "Both:   as  aslist  asstatus"
}

main "$@"
