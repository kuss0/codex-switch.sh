#!/usr/bin/env bash
set -euo pipefail

REPO_RAW_URL="${CODEX_SWITCH_RAW_URL:-https://raw.githubusercontent.com/kuss0/codex-switch.sh/main/codex-switch.sh}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
INSTALL_PATH="${CODEX_SWITCH_INSTALL_PATH:-$CODEX_HOME/codex-switch.sh}"
BIN_DIR="${CODEX_SWITCH_BIN_DIR:-$HOME/.local/bin}"

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

install_codex() {
  if ! have npm; then
    msg "npm was not found after Node.js setup." >&2
    return 1
  fi

  msg "Installing Codex CLI..."
  npm install -g @openai/codex
}

install_switcher() {
  local script_source script_dir local_switch tmp
  script_source="${BASH_SOURCE[0]:-}"
  local_switch=""

  if [ -n "$script_source" ] && [ -f "$script_source" ]; then
    case "$script_source" in
      /dev/*|/proc/*) ;;
      *)
        script_dir="$(cd "$(dirname "$script_source")" >/dev/null 2>&1 && pwd -P)"
        local_switch="$script_dir/codex-switch.sh"
        ;;
    esac
  fi

  mkdir -p "$CODEX_HOME" "$BIN_DIR"
  chmod 700 "$CODEX_HOME" 2>/dev/null || true

  tmp="$(mktemp)"
  if [ -f "$local_switch" ]; then
    cp "$local_switch" "$tmp"
  else
    download_to_stdout "$REPO_RAW_URL" > "$tmp"
  fi

  install -m 700 "$tmp" "$INSTALL_PATH"
  rm -f "$tmp"

  ln -sf "$INSTALL_PATH" "$BIN_DIR/codex-switch" 2>/dev/null || true

  "$INSTALL_PATH" init-config
  CODEX_SWITCH_SCRIPT_PATH="$INSTALL_PATH" "$INSTALL_PATH" install-shell "$HOME/.bashrc"
}

maybe_create_profile() {
  local answer name

  if [ "${CODEX_SWITCH_SKIP_PROFILE:-0}" = "1" ]; then
    return 0
  fi

  if [ -n "${CODEX_SWITCH_PROFILE:-}" ]; then
    "$INSTALL_PATH" add "$CODEX_SWITCH_PROFILE"
    "$INSTALL_PATH" use "$CODEX_SWITCH_PROFILE"
    return 0
  fi

  if ! can_prompt; then
    return 0
  fi

  prompt "Create first Codex profile now? [Y/n]: " answer
  case "$answer" in
    n|N|no|NO|No) return 0 ;;
  esac

  prompt "Initial profile name [default]: " name
  name="${name:-default}"
  "$INSTALL_PATH" add "$name"
  "$INSTALL_PATH" use "$name"
}

main() {
  msg "Installing dependencies..."
  install_packages || msg "Dependency install skipped or partially failed. Continuing..."

  install_node
  install_codex
  install_switcher
  maybe_create_profile

  msg ""
  msg "Codex switcher installed."
  msg "Open a new shell, or run: source ~/.bashrc"
  msg "Commands: cx, cxadd, cxuse, cxlist, cxwhich, cxrm"
}

main "$@"
