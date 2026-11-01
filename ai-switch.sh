#!/usr/bin/env bash

# Compatibility wrapper for the Codex profile switcher.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "ai-switch requires bash." >&2
  # shellcheck disable=SC2317
  return 1 2>/dev/null || exit 1
fi

as_is_sourced() { [ "${BASH_SOURCE[0]}" != "$0" ]; }
as_script_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P; }

# shellcheck source=/dev/null
source "$(as_script_dir)/codex-switch.sh"

as_main() {
  local command_name="${1:-status}"
  [ "$#" -eq 0 ] || shift
  case "$command_name" in
    status|which|current)
      echo "=== Codex ==="
      if command -v codex >/dev/null 2>&1; then codex --version 2>/dev/null; else echo "binary: not found"; fi
      printf 'profile: '
      cs_which
      echo "profiles:"
      cs_list
      ;;
    list|ls) cs_list "$@" ;;
    init-config) cs_init_config "$@" ;;
    install-shell) cs_install_shell "$@" ;;
    uninstall-shell) cs_uninstall_shell "$@" ;;
    codex|cx|c) cs_main "$@" ;;
    help|-h|--help)
      echo "ai-switch is a compatibility wrapper for codex-switch."
      echo "Use: cx, cxe, cxadd, cxuse, cxlist, cxwhich, cxrm"
      ;;
    *) echo "Error: unknown command: $command_name" >&2; return 1 ;;
  esac
}

if as_is_sourced; then
  ai-switch() { as_main "$@"; }
  as() { as_main status "$@"; }
  aslist() { as_main list "$@"; }
  aswhich() { as_main status "$@"; }
  asstatus() { as_main status "$@"; }
else
  as_main "$@"
fi
