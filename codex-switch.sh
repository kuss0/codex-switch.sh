#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  echo "codex-switch requires bash." >&2
  # shellcheck disable=SC2317
  return 1 2>/dev/null || exit 1
fi

_cs_is_sourced() {
  [ "${BASH_SOURCE[0]}" != "$0" ]
}

if ! _cs_is_sourced; then
  set -euo pipefail
fi

cs_home() {
  printf '%s\n' "${CODEX_HOME:-$HOME/.codex}"
}

cs_secret_dir() {
  printf '%s\n' "$(cs_home)/profile-secrets"
}

cs_current_file() {
  printf '%s\n' "$(cs_home)/current-profile"
}

cs_script_path() {
  local src
  src="${BASH_SOURCE[0]}"
  cd "$(dirname "$src")" >/dev/null 2>&1
  printf '%s/%s\n' "$(pwd -P)" "$(basename "$src")"
}

cs_die() {
  echo "Error: $*" >&2
  return 1
}

cs_can_prompt() {
  [ -t 0 ] && return 0
  [ -e /dev/tty ] || return 1
  { :; } 2>/dev/null </dev/tty >/dev/tty
}

cs_read() {
  local prompt var_name
  prompt="$1"
  var_name="$2"
  local -n target="$var_name"

  if [ -t 0 ]; then
    read -r -p "$prompt" target
  else
    # shellcheck disable=SC2034
    read -r -p "$prompt" target </dev/tty
  fi
}

cs_read_secret() {
  local prompt var_name
  prompt="$1"
  var_name="$2"
  local -n target="$var_name"

  if [ -t 0 ]; then
    read -r -s -p "$prompt" target
    echo
  else
    # shellcheck disable=SC2034
    read -r -s -p "$prompt" target </dev/tty
    printf '\n' >/dev/tty
  fi
}

cs_is_valid_name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_-]+$ ]]
}

cs_invalid_profile() {
  echo "Error: Invalid profile name: $1" >&2
  return 2
}

cs_validate_profile() {
  cs_is_valid_name "$1" || { cs_invalid_profile "$1"; return 2; }
}

cs_provider_id() {
  local name safe
  name="$1"
  safe="$(printf '%s' "$name" | tr '[:upper:]-' '[:lower:]_' | tr -c 'a-z0-9_' '_' | sed 's/^_*//;s/_*$//;s/__*/_/g')"
  [ -n "$safe" ] || safe="default"
  printf 'proxy_%s\n' "$safe"
}

cs_toml_escape() {
  local value
  value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

cs_profile_file() {
  local name
  name="$1"
  printf '%s/%s.config.toml\n' "$(cs_home)" "$name"
}

cs_secret_file() {
  local name
  name="$1"
  printf '%s/%s.env\n' "$(cs_secret_dir)" "$name"
}

cs_secret_is_legacy() {
  local secret_file line
  secret_file="$1"
  [ -f "$secret_file" ] || return 1
  IFS= read -r line < "$secret_file" || return 1
  [[ "$line" == export\ CODEX_SWITCH_API_KEY=* ]]
}

cs_current_name() {
  local file name
  file="$(cs_current_file)"
  [ -f "$file" ] || return 1
  IFS= read -r name < "$file" || return 1
  [ -n "$name" ] || return 1
  cs_validate_profile "$name" || return "$?"
  printf '%s\n' "$name"
}

cs_ensure_dirs() {
  mkdir -p "$(cs_home)" "$(cs_secret_dir)"
  chmod 700 "$(cs_home)" "$(cs_secret_dir)" 2>/dev/null || true
}

cs_add() {
  local name base_url model wire_api token provider_id profile_file secret_file keep_existing

  cs_ensure_dirs

  name="${1:-${CODEX_SWITCH_PROFILE:-}}"
  if [ -z "$name" ]; then
    if ! cs_can_prompt; then
      cs_die "Profile name is required. Set CODEX_SWITCH_PROFILE or run interactively."
      return 1
    fi
    cs_read "Profile name: " name
  fi

  if ! cs_is_valid_name "$name"; then
    cs_die "Profile name can only contain letters, numbers, hyphens, and underscores."
    return 2
  fi

  profile_file="$(cs_profile_file "$name")"
  secret_file="$(cs_secret_file "$name")"
  keep_existing="false"

  base_url="${CODEX_SWITCH_BASE_URL:-}"
  if [ -z "$base_url" ] && cs_can_prompt; then
    cs_read "Base URL: " base_url
  fi

  model="${CODEX_SWITCH_MODEL:-}"
  if [ -z "$model" ] && cs_can_prompt; then
    cs_read "Model [gpt-5.5]: " model
  fi
  model="${model:-gpt-5.5}"

  wire_api="${CODEX_SWITCH_WIRE_API:-}"
  if [ -z "$wire_api" ] && cs_can_prompt; then
    cs_read "Wire API [responses]: " wire_api
  fi
  wire_api="${wire_api:-responses}"

  token="${CODEX_SWITCH_TOKEN:-}"
  if [ -z "$token" ] && [ -n "${CODEX_SWITCH_TOKEN_FILE:-}" ]; then
    if [ ! -r "$CODEX_SWITCH_TOKEN_FILE" ]; then
      cs_die "Token file is not readable: $CODEX_SWITCH_TOKEN_FILE"
      return 1
    fi
    IFS= read -r token < "$CODEX_SWITCH_TOKEN_FILE" || true
  fi

  if [ -z "$token" ]; then
    if [ -f "$secret_file" ] && cs_can_prompt; then
      cs_read_secret "Token (blank to keep current): " token
      [ -z "$token" ] && keep_existing="true"
    elif cs_can_prompt; then
      cs_read_secret "Token: " token
    elif [ -f "$secret_file" ]; then
      keep_existing="true"
    fi
  fi

  if [ -z "$base_url" ]; then
    cs_die "Base URL cannot be empty."
    return 1
  fi

  if [ "$keep_existing" != "true" ] && [ -z "$token" ]; then
    cs_die "Token cannot be empty."
    return 1
  fi

  if [ "$keep_existing" = "true" ] && cs_secret_is_legacy "$secret_file"; then
    cs_die "Token file uses the old shell format. Re-run cxadd $name and enter the token again."
    return 1
  fi

  provider_id="$(cs_provider_id "$name")"

  cat > "$profile_file" <<EOF
model = "$(cs_toml_escape "$model")"
model_provider = "$provider_id"

[model_providers.$provider_id]
name = "$(cs_toml_escape "$name")"
base_url = "$(cs_toml_escape "$base_url")"
wire_api = "$(cs_toml_escape "$wire_api")"
env_key = "CODEX_SWITCH_API_KEY"
EOF

  chmod 600 "$profile_file" 2>/dev/null || true

  if [ "$keep_existing" != "true" ]; then
    printf '%s\n' "$token" > "$secret_file"
    chmod 600 "$secret_file" 2>/dev/null || true
  fi

  echo "Saved profile: $name"
}

cs_use() {
  local name
  name="${1:-}"
  if [ -z "$name" ]; then
    cs_die "Usage: codex-switch use <profile>"
    return 1
  fi
  cs_validate_profile "$name" || return "$?"
  if [ ! -f "$(cs_profile_file "$name")" ]; then
    cs_die "Profile not found: $name"
    return 1
  fi

  cs_ensure_dirs
  printf '%s\n' "$name" > "$(cs_current_file)"
  chmod 600 "$(cs_current_file)" 2>/dev/null || true
  echo "Current profile: $name"
}

cs_list() {
  local home current found file name mark secret_state nullglob_was_set
  home="$(cs_home)"
  current="$(cs_current_name 2>/dev/null || true)"
  found="false"

  if shopt -q nullglob; then
    nullglob_was_set="0"
  else
    nullglob_was_set="1"
  fi
  shopt -s nullglob
  for file in "$home"/*.config.toml; do
    found="true"
    name="${file##*/}"
    name="${name%.config.toml}"
    mark=" "
    [ "$name" = "$current" ] && mark="*"
    secret_state="no-token"
    [ -f "$(cs_secret_file "$name")" ] && secret_state="token"
    printf '%s %-24s %s\n' "$mark" "$name" "$secret_state"
  done

  if [ "$found" != "true" ]; then
    echo "No profiles found. Run: cxadd"
  fi

  [ "$nullglob_was_set" -eq 0 ] || shopt -u nullglob
}

cs_which() {
  local current
  current="$(cs_current_name 2>/dev/null || true)"
  if [ -n "$current" ]; then
    echo "$current"
  else
    echo "No current profile. Codex will use $(cs_home)/config.toml only."
  fi
}

cs_load_secret() {
  local name secret_file
  name="$1"
  secret_file="$(cs_secret_file "$name")"

  cs_validate_profile "$name" || return "$?"
  if [ ! -f "$secret_file" ]; then
    cs_die "Token file not found for profile: $name"
    return 1
  fi
  unset CODEX_SWITCH_API_KEY
  IFS= read -r CODEX_SWITCH_API_KEY < "$secret_file" || true
  if [[ "$CODEX_SWITCH_API_KEY" == export\ CODEX_SWITCH_API_KEY=* ]]; then
    cs_die "Token file uses the old shell format. Re-run: cxadd $name"
    return 1
  fi
  if [ -z "${CODEX_SWITCH_API_KEY:-}" ]; then
    cs_die "Token is empty for profile: $name"
    return 1
  fi
  export CODEX_SWITCH_API_KEY
}

cs_selected_profile() {
  local profile

  if [ -n "${CODEX_PROFILE:-}" ]; then
    profile="$CODEX_PROFILE"
    cs_validate_profile "$profile" || return "$?"
    printf '%s\n' "$profile"
    return 0
  fi

  [ -f "$(cs_current_file)" ] || return 1
  cs_current_name
}

cs_run() {
  local profile status

  if profile="$(cs_selected_profile)"; then
    if [ ! -f "$(cs_profile_file "$profile")" ]; then
      cs_die "Profile not found: $profile"
      return 1
    fi
    (
      cs_load_secret "$profile" || exit "$?"
      command codex --profile "$profile" "$@"
    )
  else
    status="$?"
    [ "$status" -eq 1 ] || return "$status"
    command codex "$@"
  fi
}

cs_exec() {
  local profile status

  if profile="$(cs_selected_profile)"; then
    if [ ! -f "$(cs_profile_file "$profile")" ]; then
      cs_die "Profile not found: $profile"
      return 1
    fi
    (
      cs_load_secret "$profile" || exit "$?"
      command codex exec --profile "$profile" "$@"
    )
  else
    status="$?"
    [ "$status" -eq 1 ] || return "$status"
    command codex exec "$@"
  fi
}

cs_remove() {
  local name current
  name="${1:-}"
  if [ -z "$name" ]; then
    cs_die "Usage: codex-switch remove <profile>"
    return 1
  fi
  cs_validate_profile "$name" || return "$?"

  rm -f "$(cs_profile_file "$name")" "$(cs_secret_file "$name")"
  current="$(cs_current_name 2>/dev/null || true)"
  if [ "$current" = "$name" ]; then
    rm -f "$(cs_current_file)"
  fi
  echo "Removed profile: $name"
}

cs_init_config() {
  local config
  cs_ensure_dirs
  config="$(cs_home)/config.toml"

  if [ -f "$config" ]; then
    echo "Kept existing config: $config"
    return 0
  fi

  cat > "$config" <<'EOF'
# Codex base config. Provider/model settings are selected by profiles.
approval_policy = "on-request"
sandbox_mode = "workspace-write"
EOF
  chmod 600 "$config" 2>/dev/null || true
  echo "Created config: $config"
}

cs_install_shell() {
  local rc_file script_path
  script_path="${CODEX_SWITCH_SCRIPT_PATH:-$(cs_script_path)}"
  rc_file="${1:-${CODEX_SWITCH_RC_FILE:-$HOME/.bashrc}}"

  touch "$rc_file"
  sed -i '/# >>> codex-switch >>>/,/# <<< codex-switch <<</d' "$rc_file"
  cat >> "$rc_file" <<EOF

# >>> codex-switch >>>
source "$script_path"
# <<< codex-switch <<<
EOF
  echo "Installed shell hook: $rc_file"
}

cs_uninstall_shell() {
  local rc_file
  rc_file="${1:-${CODEX_SWITCH_RC_FILE:-$HOME/.bashrc}}"
  [ -f "$rc_file" ] || return 0
  sed -i '/# >>> codex-switch >>>/,/# <<< codex-switch <<</d' "$rc_file"
  echo "Removed shell hook: $rc_file"
}

cs_help() {
  cat <<'EOF'
codex-switch - Codex profile switcher

Usage:
  codex-switch add [name]       Add or update a profile
  codex-switch use <name>       Set current profile
  codex-switch list             List profiles
  codex-switch current          Show current profile
  codex-switch run [args...]    Run codex with current profile
  codex-switch exec [args...]   Run codex exec with current profile
  codex-switch remove <name>    Remove a profile
  codex-switch init-config      Create base ~/.codex/config.toml if missing
  codex-switch install-shell    Add cx helpers to ~/.bashrc
  codex-switch uninstall-shell  Remove cx helpers from ~/.bashrc

Shell helpers after sourcing:
  cx [args...]          codex with current profile
  cxe [args...]         codex exec with current profile
  cxadd [name]          add/update profile
  cxuse <name>          switch profile
  cxlist                list profiles
  cxwhich               show current profile
  cxrm <name>           remove profile

Environment for non-interactive add:
  CODEX_SWITCH_PROFILE
  CODEX_SWITCH_BASE_URL
  CODEX_SWITCH_MODEL
  CODEX_SWITCH_WIRE_API
  CODEX_SWITCH_TOKEN
  CODEX_SWITCH_TOKEN_FILE
EOF
}

cs_main() {
  local command_name
  command_name="${1:-help}"
  if [ "$#" -gt 0 ]; then
    shift
  fi

  case "$command_name" in
    add) cs_add "$@" ;;
    use|switch) cs_use "$@" ;;
    list|ls) cs_list "$@" ;;
    current|which) cs_which "$@" ;;
    run) cs_run "$@" ;;
    exec) cs_exec "$@" ;;
    remove|rm) cs_remove "$@" ;;
    init-config) cs_init_config "$@" ;;
    install-shell) cs_install_shell "$@" ;;
    uninstall-shell) cs_uninstall_shell "$@" ;;
    help|-h|--help) cs_help ;;
    *) cs_die "Unknown command: $command_name" ;;
  esac
}

if _cs_is_sourced; then
  codex-switch() { cs_main "$@"; }
  cx() { cs_main run "$@"; }
  cxe() { cs_main exec "$@"; }
  cxadd() { cs_main add "$@"; }
  cxuse() { cs_main use "$@"; }
  cxlist() { cs_main list "$@"; }
  cxwhich() { cs_main current "$@"; }
  cxrm() { cs_main remove "$@"; }
else
  cs_main "$@"
fi
