#!/usr/bin/env bash
set -euo pipefail

# Install Codex CLI and the Codex profile switcher.

REPO_RAW_BASE="${AI_SWITCH_RAW_BASE:-https://raw.githubusercontent.com/kuss0/codex-switch.sh/main}"
SHARE_DIR="${AI_SWITCH_SHARE_DIR:-$HOME/.local/share/ai-switch}"
BIN_DIR="${AI_SWITCH_BIN_DIR:-$HOME/.local/bin}"

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

  msg "Installing current Node.js LTS..."
  fnm install --lts --use
  fnm default "$(node --version)"
  load_fnm
}

install_clis() {
  local latest actual
  if ! have npm; then
    msg "npm was not found after Node.js setup." >&2
    return 1
  fi

  msg "Installing latest stable Codex CLI from the official npm registry..."
  latest="$(npm view @openai/codex@latest version --registry=https://registry.npmjs.org/)"
  npm install -g @openai/codex@latest --registry=https://registry.npmjs.org/
  hash -r
  actual="$(codex --version)"
  msg "Codex path: $(command -v codex)"
  msg "$actual"
  msg "Official latest stable: $latest"
  if [ "$actual" != "codex-cli $latest" ]; then
    msg "The current PATH points to a different Codex version. Check your Node environment and Codex path." >&2
    return 1
  fi
}

install_switcher() (
  local script_source script_dir local_dir stage_dir backup_dir source_name
  script_source="${BASH_SOURCE[0]:-}"
  local_dir=""

  if [ -n "$script_source" ] && [ -f "$script_source" ]; then
    case "$script_source" in
      /dev/*|/proc/*) ;;
      *)
        script_dir="$(cd "$(dirname "$script_source")" >/dev/null 2>&1 && pwd -P)"
        if [ -f "$script_dir/ai-switch.sh" ] && [ -f "$script_dir/codex-switch.sh" ]; then
          local_dir="$script_dir"
        fi
        ;;
    esac
  fi

  mkdir -p "$SHARE_DIR" "$BIN_DIR" "$HOME/.codex"
  chmod 700 "$HOME/.codex" 2>/dev/null || true
  stage_dir="$(mktemp -d "$SHARE_DIR/.install.XXXXXX")"
  trap 'rm -rf -- "$stage_dir"' EXIT

  # Finish downloading and validating before replacing any installed file.
  for source_name in ai-switch.sh codex-switch.sh zz.sh tmux.conf; do
    if [ -d "$SHARE_DIR/$source_name" ]; then
      msg "Cannot replace a directory: $SHARE_DIR/$source_name" >&2
      return 1
    fi
    if [ -n "$local_dir" ] && [ -f "$local_dir/$source_name" ]; then
      cp "$local_dir/$source_name" "$stage_dir/$source_name"
    else
      download_to_file "$REPO_RAW_BASE/$source_name" "$stage_dir/$source_name"
    fi
    if [ ! -s "$stage_dir/$source_name" ]; then
      msg "Downloaded file is empty: $source_name" >&2
      return 1
    fi
    if [ "$source_name" = tmux.conf ]; then
      chmod 600 "$stage_dir/$source_name"
    else
      bash -n "$stage_dir/$source_name"
      chmod 700 "$stage_dir/$source_name"
    fi
  done

  for source_name in ai-switch codex-switch zz; do
    if [ -d "$BIN_DIR/$source_name" ] && [ ! -L "$BIN_DIR/$source_name" ]; then
      msg "Cannot replace a directory: $BIN_DIR/$source_name" >&2
      return 1
    fi
  done
  # Back up standalone commands and foreign links, including dangling links.
  if [ -e "$BIN_DIR/zz" ] || [ -L "$BIN_DIR/zz" ]; then
    if [ ! -L "$BIN_DIR/zz" ] || [ "$(readlink "$BIN_DIR/zz")" != "$SHARE_DIR/zz.sh" ]; then
      mkdir -p "$SHARE_DIR/install-backups"
      chmod 700 "$SHARE_DIR/install-backups"
      backup_dir="$(mktemp -d "$SHARE_DIR/install-backups/zz.XXXXXX")"
      cp -Pp -- "$BIN_DIR/zz" "$backup_dir/zz"
      msg "Backed up existing zz: $backup_dir/zz"
    fi
  fi

  for source_name in ai-switch.sh codex-switch.sh zz.sh tmux.conf; do
    mv -f -- "$stage_dir/$source_name" "$SHARE_DIR/$source_name"
  done
  ln -sfn "$SHARE_DIR/ai-switch.sh" "$BIN_DIR/ai-switch"
  ln -sfn "$SHARE_DIR/codex-switch.sh" "$BIN_DIR/codex-switch"
  ln -sfn "$SHARE_DIR/zz.sh" "$BIN_DIR/zz"

  # Keep legacy paths working.
  ln -sfn "$SHARE_DIR/codex-switch.sh" "$HOME/.codex/codex-switch.sh"

  "$SHARE_DIR/ai-switch.sh" init-config
  CODEX_SWITCH_BIN_DIR="$BIN_DIR" CODEX_SWITCH_SCRIPT_PATH="$SHARE_DIR/codex-switch.sh" "$SHARE_DIR/ai-switch.sh" install-shell "$HOME/.bashrc"
)

maybe_install_tmux() {
  local answer
  case "${CODEX_SWITCH_INSTALL_TMUX:-ask}" in
    1|yes|true) answer=y ;;
    0|no|false) return 0 ;;
    ask)
      can_prompt || return 0
      prompt '是否启用 tmux 断线保活？[y/N]: ' answer
      ;;
    *) msg 'CODEX_SWITCH_INSTALL_TMUX must be 0 or 1.' >&2; return 2 ;;
  esac
  case "$answer" in
    y|Y|yes|YES|Yes) "$SHARE_DIR/codex-switch.sh" tmux-install ;;
    *) msg 'Skipped optional tmux installation. Run codex directly.' ;;
  esac
}

maybe_create_profiles() {
  local answer name

  if [ "${AI_SWITCH_SKIP_PROFILE:-0}" = "1" ]; then
    return 0
  fi

  # Non-interactive codex profile
  if [ -n "${CODEX_SWITCH_PROFILE:-}" ]; then
    "$SHARE_DIR/codex-switch.sh" add "$CODEX_SWITCH_PROFILE"
  fi

  if [ -n "${CODEX_SWITCH_PROFILE:-}" ]; then
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
      ;;
  esac

}

main() {
  if [ "${1:-}" = --switcher-only ] && [ "$#" -eq 1 ]; then
    install_switcher
    msg 'Updated the switcher and zz. Run ~/.local/bin/zz reload to apply tmux settings to a running server.'
    msg 'Reload ~/.bashrc or open a new shell for shell helpers.'
    return
  fi
  if [ "$#" -ne 0 ]; then
    msg 'Usage: install.sh [--switcher-only]' >&2
    return 2
  fi
  msg "Installing dependencies..."
  install_packages || msg "Dependency install skipped or partially failed. Continuing..."

  install_node
  install_clis
  install_switcher
  maybe_install_tmux
  maybe_create_profiles

  msg ""
  msg "Codex switcher installed."
  msg "After adding/selecting a profile, run codex directly. No alias is required."
  msg "Open a new shell, or run: source ~/.bashrc"
  msg ""
  msg "Codex:  cx  cxe  cxadd  cxuse  cxlist  cxwhich  cxrm"
  msg "Optional keepalive: zz / zz work / zz ls; F12 returns to SSH."
  msg "Check/update: codex-switch version / codex-switch update"
  msg "Compatibility: ai-switch / as / asstatus"
}

main "$@"
