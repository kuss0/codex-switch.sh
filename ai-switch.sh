#!/usr/bin/env bash

# ai-switch: Codex + Grok profile switcher (2-in-1)
# Shell helpers: cx* for Codex, gx* for Grok

if [ -z "${BASH_VERSION:-}" ]; then
  echo "ai-switch requires bash." >&2
  # shellcheck disable=SC2317
  return 1 2>/dev/null || exit 1
fi

_as_is_sourced() {
  [ "${BASH_SOURCE[0]}" != "$0" ]
}

if ! _as_is_sourced; then
  set -euo pipefail
fi

as_script_dir() {
  local src dir
  src="${BASH_SOURCE[0]}"
  dir="$(cd "$(dirname "$src")" >/dev/null 2>&1 && pwd -P)"
  printf '%s\n' "$dir"
}

as_script_path() {
  printf '%s/%s\n' "$(as_script_dir)" "$(basename "${BASH_SOURCE[0]}")"
}

as_load_modules() {
  local dir
  dir="$(as_script_dir)"
  # shellcheck source=/dev/null
  source "$dir/codex-switch.sh"
  # shellcheck source=/dev/null
  source "$dir/grok-switch.sh"
}

as_die() {
  echo "Error: $*" >&2
  return 1
}

as_status() {
  echo "=== Codex ==="
  if command -v codex >/dev/null 2>&1; then
    echo "binary: $(command -v codex)"
    codex --version 2>/dev/null || true
  else
    echo "binary: not found"
  fi
  echo -n "profile: "
  cs_which 2>/dev/null || echo "(unavailable)"
  echo "profiles:"
  cs_list 2>/dev/null || echo "  (none)"
  echo
  echo "=== Grok ==="
  if command -v grok >/dev/null 2>&1; then
    echo "binary: $(command -v grok)"
    grok --version 2>/dev/null || true
  else
    echo "binary: not found"
  fi
  echo -n "profile: "
  gs_which 2>/dev/null || echo "(unavailable)"
  echo "profiles:"
  gs_list 2>/dev/null || echo "  (none)"
}

as_list() {
  echo "Codex:"
  cs_list
  echo
  echo "Grok:"
  gs_list
}

as_install_shell() {
  local rc_file script_path
  script_path="${AI_SWITCH_SCRIPT_PATH:-$(as_script_path)}"
  rc_file="${1:-${AI_SWITCH_RC_FILE:-$HOME/.bashrc}}"

  touch "$rc_file"
  # Remove legacy single-tool hooks and our own block
  sed -i '/# >>> codex-switch >>>/,/# <<< codex-switch <<</d' "$rc_file"
  sed -i '/# >>> grok-switch >>>/,/# <<< grok-switch <<</d' "$rc_file"
  sed -i '/# >>> ai-switch >>>/,/# <<< ai-switch <<</d' "$rc_file"
  cat >> "$rc_file" <<EOF

# >>> ai-switch >>>
source "$script_path"
# <<< ai-switch <<<
EOF
  echo "Installed shell hook: $rc_file"
  echo "Helpers: cx* (Codex)  gx* (Grok)  as / aslist / aswhich (both)"
}

as_uninstall_shell() {
  local rc_file
  rc_file="${1:-${AI_SWITCH_RC_FILE:-$HOME/.bashrc}}"
  [ -f "$rc_file" ] || return 0
  sed -i '/# >>> codex-switch >>>/,/# <<< codex-switch <<</d' "$rc_file"
  sed -i '/# >>> grok-switch >>>/,/# <<< grok-switch <<</d' "$rc_file"
  sed -i '/# >>> ai-switch >>>/,/# <<< ai-switch <<</d' "$rc_file"
  echo "Removed shell hooks: $rc_file"
}

as_init_config() {
  cs_init_config
  gs_init_config
}

as_help() {
  cat <<'EOF'
ai-switch - Codex + Grok profile switcher (2-in-1)

Usage:
  ai-switch status              Show both tools + current profiles
  ai-switch list                List all Codex + Grok profiles
  ai-switch init-config         Create base configs if missing
  ai-switch install-shell       Add helpers to ~/.bashrc
  ai-switch uninstall-shell     Remove helpers from ~/.bashrc

  ai-switch codex <cmd> ...     Forward to codex-switch
  ai-switch grok  <cmd> ...     Forward to grok-switch

Shell helpers after sourcing:
  Codex:
    cx / cxe / cxadd / cxuse / cxlist / cxwhich / cxrm
  Grok:
    gx / gxe / gxadd / gxuse / gxlist / gxwhich / gxrm
  Combined:
    as / aslist / aswhich / asstatus

Examples:
  cxadd proxy1 && cxuse proxy1 && cx
  gxadd proxy1 && gxuse proxy1 && gx
  aslist
  asstatus

Also available as standalone commands when installed:
  codex-switch ...
  grok-switch ...
EOF
}

as_main() {
  local command_name
  command_name="${1:-help}"
  if [ "$#" -gt 0 ]; then
    shift
  fi

  case "$command_name" in
    status|which|current) as_status ;;
    list|ls) as_list ;;
    init-config) as_init_config ;;
    install-shell) as_install_shell "$@" ;;
    uninstall-shell) as_uninstall_shell "$@" ;;
    codex|cx|c)
      cs_main "$@"
      ;;
    grok|gx|g)
      gs_main "$@"
      ;;
    help|-h|--help) as_help ;;
    *)
      as_die "Unknown command: $command_name (try: ai-switch help)"
      ;;
  esac
}

# Always load modules (needed for both source and exec modes)
as_load_modules

if _as_is_sourced; then
  ai-switch() { as_main "$@"; }
  as() { as_main status "$@"; }
  aslist() { as_main list "$@"; }
  aswhich() { as_main status "$@"; }
  asstatus() { as_main status "$@"; }
  # codex-switch / grok-switch / cx* / gx* already defined by modules
else
  as_main "$@"
fi
