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
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
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
  [[ "$line" == export\ CODEX_SWITCH_API_KEY=* || "$line" == export\ OPENAI_API_KEY=* ]]
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

cs_copy_config() {
  local source dest tmp
  source="$1"
  dest="$2"
  tmp="$(mktemp "${dest}.tmp.XXXXXX")" || return 1
  if ! cp -- "$source" "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    cs_die 'Could not replace configuration.'
    return 1
  fi
}

cs_backup_config() {
  local home backup
  home="$(cs_home)"
  [ -f "$home/config.toml" ] || return 0
  mkdir -p "$home/config-backups" || return 1
  chmod 700 "$home/config-backups" || return 1
  if [ ! -f "$home/config.toml.before-codex-switch" ]; then
    cs_copy_config "$home/config.toml" "$home/config.toml.before-codex-switch" || return 1
  fi
  backup="$(mktemp "$home/config-backups/config.XXXXXX.toml")" || return 1
  cs_copy_config "$home/config.toml" "$backup"
}

cs_restore() {
  local home
  home="$(cs_home)"
  if [ ! -f "$home/config.toml.before-codex-switch" ]; then
    cs_die 'No original configuration backup exists.'
    return 1
  fi
  cs_backup_config || return 1
  cs_copy_config "$home/config.toml.before-codex-switch" "$home/config.toml" || return 1
  rm -f -- "$(cs_current_file)"
  echo 'Restored original config.toml. Latest configuration retained in config-backups/.'
}

cs_add() {
  local name base_url model wire_api token provider_id profile_file secret_file keep_existing tmp_profile

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
    cs_read "API 地址: " base_url
  fi

  model="${CODEX_SWITCH_MODEL:-}"
  if [ -z "$model" ] && cs_can_prompt; then
    cs_read "Model [gpt-5.5]: " model
  fi
  model="${model:-gpt-5.5}"

  wire_api="${CODEX_SWITCH_WIRE_API:-}"
  wire_api="${wire_api:-responses}"
  if [ "$wire_api" != responses ]; then
    cs_die 'Only Wire API responses is supported. Set CODEX_SWITCH_WIRE_API=responses.'
    return 1
  fi

  token="${CODEX_SWITCH_TOKEN:-}"
  if [ -z "$token" ] && [ -n "${CODEX_SWITCH_TOKEN_FILE:-}" ]; then
    if [ ! -r "$CODEX_SWITCH_TOKEN_FILE" ]; then
      cs_die "Token file is not readable: $CODEX_SWITCH_TOKEN_FILE"
      return 1
    fi
    token="$(< "$CODEX_SWITCH_TOKEN_FILE")"
  fi

  if [ -z "$token" ]; then
    if [ -f "$secret_file" ] && cs_can_prompt; then
      cs_read_secret "API Key (hidden; blank to keep current): " token
      [ -z "$token" ] && keep_existing="true"
    elif cs_can_prompt; then
      cs_read_secret "API Key (hidden): " token
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

  if [ "$keep_existing" = "true" ]; then
    token="$(< "$secret_file")"
  fi
  if [ -z "$token" ] || [[ "$token" == *$'\n'* || "$token" == *$'\r'* ]]; then
    cs_die 'Token must be a nonempty single line.'
    return 1
  fi

  provider_id="$(cs_provider_id "$name")"

  tmp_profile="$(mktemp "$(cs_home)/.config.XXXXXX")" || return 1
  cat > "$tmp_profile" <<EOF
# Complete configuration managed by codex-switch.
model = "$(cs_toml_escape "$model")"
model_provider = "$provider_id"
approval_policy = "on-request"
sandbox_mode = "workspace-write"

[model_providers.$provider_id]
name = "$(cs_toml_escape "$name")"
base_url = "$(cs_toml_escape "$base_url")"
wire_api = "$(cs_toml_escape "$wire_api")"
requires_openai_auth = false
experimental_bearer_token = "$(cs_toml_escape "$token")"
EOF
  cs_copy_config "$tmp_profile" "$profile_file" || { rm -f -- "$tmp_profile"; return 1; }
  rm -f -- "$tmp_profile"

  chmod 600 "$profile_file" 2>/dev/null || true

  if [ "$keep_existing" != "true" ]; then
    (umask 077; printf '%s\n' "$token" > "$secret_file") || return 1
    chmod 600 "$secret_file" 2>/dev/null || true
  fi

  echo "Saved profile: $name"
  cs_use "$name"
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
  if grep -Eq '^env_key = "(OPENAI_API_KEY|CODEX_SWITCH_API_KEY)"' "$(cs_profile_file "$name")"; then
    cs_die "This is an old environment-based profile. Run: codex-switch add $name (blank token keeps the stored key)."
    return 1
  fi
  cs_init_config >/dev/null || return 1
  cs_backup_config || return 1
  cs_copy_config "$(cs_profile_file "$name")" "$(cs_home)/config.toml" || return 1
  (umask 077; printf '%s\n' "$name" > "$(cs_current_file)") || return 1
  echo "Current profile: $name"
  echo 'Replaced complete config.toml; previous settings are in config-backups/.'
  echo 'Ready: run codex directly (no shell alias or exported token needed).'
}

cs_save() {
  local name
  name="${1:-}"
  cs_validate_profile "$name" || return "$?"
  [ -f "$(cs_home)/config.toml" ] || { cs_die 'No config.toml to save.'; return 1; }
  cs_ensure_dirs
  cs_copy_config "$(cs_home)/config.toml" "$(cs_profile_file "$name")" || return 1
  echo "Saved complete current configuration as: $name"
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

cs_run() {
  command codex "$@"
}

cs_exec() {
  command codex exec "$@"
}

cs_remove() {
  local name current
  name="${1:-}"
  if [ -z "$name" ]; then
    cs_die "Usage: codex-switch remove <profile>"
    return 1
  fi
  cs_validate_profile "$name" || return "$?"

  current="$(cs_current_name 2>/dev/null || true)"
  if [ "$current" = "$name" ]; then
    cs_restore || return "$?"
  fi
  rm -f "$(cs_profile_file "$name")" "$(cs_secret_file "$name")"
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
# Codex base config. codex-switch replaces this with a complete saved config.
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
  codex-switch                  Open interactive API configuration menu
  codex-switch api [name]       Add/edit API address, API Key and model
  codex-switch add [name]       Create and activate a complete configuration
  codex-switch use <name>       Back up and replace config.toml with saved config
  codex-switch save <name>      Save current config.toml, including custom settings
  codex-switch restore          Restore original config.toml
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

cs_menu() {
  local choice name
  while true; do
    printf '\n%s\n' 'Codex API 配置维护'
    printf '%s\n' '1) 添加/修改 API（地址、API Key、模型）' '2) 切换已保存的 API 配置' '3) 列出配置' '4) 保存当前完整配置' '5) 恢复原始配置' '0) 退出'
    cs_read '选择 [0-5]: ' choice || return 0
    case "$choice" in
      1) cs_add || return "$?" ;;
      2|4)
        cs_read 'Profile name: ' name || return 0
        if [ "$choice" = 2 ]; then cs_use "$name" || return "$?"; else cs_save "$name" || return "$?"; fi
        ;;
      3) cs_list ;;
      5) cs_restore || return "$?" ;;
      0) return 0 ;;
      *) printf '%s\n' '请输入 0 到 5。' ;;
    esac
  done
}

cs_main() {
  local command_name
  if [ "$#" -eq 0 ]; then
    if cs_can_prompt; then cs_menu; else cs_help; fi
    return "$?"
  fi
  command_name="${1:-help}"
  if [ "$#" -gt 0 ]; then
    shift
  fi

  case "$command_name" in
    add|api|edit) cs_add "$@" ;;
    menu) cs_menu ;;
    use|switch) cs_use "$@" ;;
    save) cs_save "$@" ;;
    restore) cs_restore "$@" ;;
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
