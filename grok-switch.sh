#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  echo "grok-switch requires bash." >&2
  # shellcheck disable=SC2317
  return 1 2>/dev/null || exit 1
fi

_gs_is_sourced() {
  [ "${BASH_SOURCE[0]}" != "$0" ]
}

if ! _gs_is_sourced; then
  set -euo pipefail
fi

gs_home() {
  printf '%s\n' "${GROK_HOME:-$HOME/.grok}"
}

gs_secret_dir() {
  printf '%s\n' "$(gs_home)/profile-secrets"
}

gs_profile_dir() {
  printf '%s\n' "$(gs_home)/profiles"
}

gs_current_file() {
  printf '%s\n' "$(gs_home)/current-profile"
}

gs_config_file() {
  printf '%s\n' "$(gs_home)/config.toml"
}

gs_script_path() {
  local src
  src="${BASH_SOURCE[0]}"
  cd "$(dirname "$src")" >/dev/null 2>&1
  printf '%s/%s\n' "$(pwd -P)" "$(basename "$src")"
}

gs_die() {
  echo "Error: $*" >&2
  return 1
}

gs_can_prompt() {
  [ -t 0 ] && return 0
  [ -e /dev/tty ] || return 1
  { :; } 2>/dev/null </dev/tty >/dev/tty
}

gs_read() {
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

gs_read_secret() {
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

gs_is_valid_name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_-]+$ ]]
}

gs_invalid_profile() {
  echo "Error: Invalid profile name: $1" >&2
  return 2
}

gs_validate_profile() {
  gs_is_valid_name "$1" || { gs_invalid_profile "$1"; return 2; }
}

gs_toml_escape() {
  local value
  value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

gs_profile_file() {
  local name
  name="$1"
  printf '%s/%s.toml\n' "$(gs_profile_dir)" "$name"
}

gs_secret_file() {
  local name
  name="$1"
  printf '%s/%s.env\n' "$(gs_secret_dir)" "$name"
}

gs_current_name() {
  local file name
  file="$(gs_current_file)"
  [ -f "$file" ] || return 1
  IFS= read -r name < "$file" || return 1
  [ -n "$name" ] || return 1
  gs_validate_profile "$name" || return "$?"
  printf '%s\n' "$name"
}

gs_ensure_dirs() {
  mkdir -p "$(gs_home)" "$(gs_secret_dir)" "$(gs_profile_dir)"
  chmod 700 "$(gs_home)" "$(gs_secret_dir)" "$(gs_profile_dir)" 2>/dev/null || true
}

gs_profile_get() {
  local file key line value
  file="$1"
  key="$2"
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key"[[:space:]]*=*)
        value="${line#*=}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "$value" == \"*\" ]]; then
          value="${value:1:${#value}-2}"
          value="${value//\\\"/\"}"
          value="${value//\\\\/\\}"
        fi
        printf '%s\n' "$value"
        return 0
        ;;
    esac
  done < "$file"
  return 1
}

# Remove a top-level TOML table like [model.name] from config.
gs_remove_toml_section() {
  local config header tmp in_section
  config="$1"
  header="$2"
  [ -f "$config" ] || return 0

  tmp="$(mktemp)"
  in_section="false"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$header" ]; then
      in_section="true"
      continue
    fi
    if [ "$in_section" = "true" ]; then
      case "$line" in
        \[*) in_section="false" ;;
        *) continue ;;
      esac
    fi
    if [ "$in_section" = "false" ]; then
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$config"

  mv "$tmp" "$config"
}

gs_append_model_section() {
  local config name model base_url display_name api_backend
  config="$1"
  name="$2"
  model="$3"
  base_url="$4"
  display_name="$5"
  api_backend="$6"

  {
    printf '\n[model.%s]\n' "$name"
    printf 'model = "%s"\n' "$(gs_toml_escape "$model")"
    printf 'base_url = "%s"\n' "$(gs_toml_escape "$base_url")"
    printf 'name = "%s"\n' "$(gs_toml_escape "$display_name")"
    printf 'api_backend = "%s"\n' "$(gs_toml_escape "$api_backend")"
    printf 'env_key = "GROK_SWITCH_API_KEY"\n'
    printf 'supports_reasoning_effort = true\n'
    printf 'reasoning_efforts = [\n'
    printf '    "low",\n'
    printf '    "medium",\n'
    printf '    "high",\n'
    printf ']\n'
  } >> "$config"
}

gs_set_models_default() {
  local name config tmp in_models done_default
  name="$1"
  config="$(gs_config_file)"

  if [ ! -f "$config" ]; then
    cat > "$config" <<EOF
# Grok base config. Model endpoints are managed by grok-switch profiles.
[models]
default = "$(gs_toml_escape "$name")"
EOF
    chmod 600 "$config" 2>/dev/null || true
    return 0
  fi

  tmp="$(mktemp)"
  in_models="false"
  done_default="false"

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      \[models\])
        if [ "$in_models" = "true" ] && [ "$done_default" != "true" ]; then
          printf 'default = "%s"\n' "$(gs_toml_escape "$name")" >> "$tmp"
          done_default="true"
        fi
        in_models="true"
        printf '%s\n' "$line" >> "$tmp"
        continue
        ;;
      \[*)
        if [ "$in_models" = "true" ] && [ "$done_default" != "true" ]; then
          printf 'default = "%s"\n' "$(gs_toml_escape "$name")" >> "$tmp"
          done_default="true"
        fi
        in_models="false"
        printf '%s\n' "$line" >> "$tmp"
        continue
        ;;
    esac

    if [ "$in_models" = "true" ] && [[ "$line" =~ ^default[[:space:]]*= ]]; then
      printf 'default = "%s"\n' "$(gs_toml_escape "$name")" >> "$tmp"
      done_default="true"
      continue
    fi

    printf '%s\n' "$line" >> "$tmp"
  done < "$config"

  if [ "$in_models" = "true" ] && [ "$done_default" != "true" ]; then
    printf 'default = "%s"\n' "$(gs_toml_escape "$name")" >> "$tmp"
    done_default="true"
  fi

  if [ "$done_default" != "true" ]; then
    {
      printf '\n[models]\n'
      printf 'default = "%s"\n' "$(gs_toml_escape "$name")"
    } >> "$tmp"
  fi

  mv "$tmp" "$config"
  chmod 600 "$config" 2>/dev/null || true
}

gs_apply_profile_to_config() {
  local name model base_url display_name api_backend profile_file config
  name="$1"
  profile_file="$(gs_profile_file "$name")"
  config="$(gs_config_file)"

  [ -f "$profile_file" ] || {
    gs_die "Profile not found: $name"
    return 1
  }

  model="$(gs_profile_get "$profile_file" model)"
  base_url="$(gs_profile_get "$profile_file" base_url)"
  display_name="$(gs_profile_get "$profile_file" name 2>/dev/null || true)"
  api_backend="$(gs_profile_get "$profile_file" api_backend 2>/dev/null || true)"
  display_name="${display_name:-$name}"
  api_backend="${api_backend:-responses}"

  if [ -z "$model" ] || [ -z "$base_url" ]; then
    gs_die "Profile is incomplete (need model + base_url): $name"
    return 1
  fi

  gs_ensure_dirs
  if [ ! -f "$config" ]; then
    gs_init_config >/dev/null
  fi

  gs_remove_toml_section "$config" "[model.$name]"
  gs_append_model_section "$config" "$name" "$model" "$base_url" "$display_name" "$api_backend"
  gs_set_models_default "$name"
}

gs_add() {
  local name base_url model api_backend display_name token profile_file secret_file keep_existing
  local advanced

  gs_ensure_dirs

  name="${1:-${GROK_SWITCH_PROFILE:-}}"
  if [ -z "$name" ]; then
    if ! gs_can_prompt; then
      gs_die "Profile name is required. Set GROK_SWITCH_PROFILE or run interactively."
      return 1
    fi
    gs_read "Profile name: " name
  fi

  if ! gs_is_valid_name "$name"; then
    gs_die "Profile name can only contain letters, numbers, hyphens, and underscores."
    return 2
  fi

  profile_file="$(gs_profile_file "$name")"
  secret_file="$(gs_secret_file "$name")"
  keep_existing="false"

  # Interactive default: only Base URL + API Key.
  # Model / backend / display name default unless env or GROK_SWITCH_ADVANCED=1.
  base_url="${GROK_SWITCH_BASE_URL:-}"
  if [ -z "$base_url" ] && gs_can_prompt; then
    gs_read "Base URL: " base_url
  fi

  token="${GROK_SWITCH_TOKEN:-${GROK_SWITCH_API_KEY:-}}"
  if [ -z "$token" ] && [ -n "${GROK_SWITCH_TOKEN_FILE:-${GROK_SWITCH_API_KEY_FILE:-}}" ]; then
    local token_file
    token_file="${GROK_SWITCH_TOKEN_FILE:-${GROK_SWITCH_API_KEY_FILE}}"
    if [ ! -r "$token_file" ]; then
      gs_die "API key file is not readable: $token_file"
      return 1
    fi
    IFS= read -r token < "$token_file" || true
  fi

  if [ -z "$token" ]; then
    if [ -f "$secret_file" ] && gs_can_prompt; then
      gs_read_secret "API Key (blank to keep current): " token
      [ -z "$token" ] && keep_existing="true"
    elif gs_can_prompt; then
      gs_read_secret "API Key: " token
    elif [ -f "$secret_file" ]; then
      keep_existing="true"
    fi
  fi

  model="${GROK_SWITCH_MODEL:-}"
  api_backend="${GROK_SWITCH_API_BACKEND:-}"
  display_name="${GROK_SWITCH_DISPLAY_NAME:-}"
  advanced="${GROK_SWITCH_ADVANCED:-0}"

  if [ "$advanced" = "1" ] && gs_can_prompt; then
    if [ -z "$model" ]; then
      gs_read "Model [grok-4.5]: " model
    fi
    if [ -z "$api_backend" ]; then
      gs_read "API backend [responses]: " api_backend
    fi
    if [ -z "$display_name" ]; then
      gs_read "Display name [$name]: " display_name
    fi
  fi

  model="${model:-grok-4.5}"
  api_backend="${api_backend:-responses}"
  display_name="${display_name:-$name}"

  if [ -z "$base_url" ]; then
    gs_die "Base URL cannot be empty."
    return 1
  fi

  if [ "$keep_existing" != "true" ] && [ -z "$token" ]; then
    gs_die "API Key cannot be empty."
    return 1
  fi

  cat > "$profile_file" <<EOF
model = "$(gs_toml_escape "$model")"
base_url = "$(gs_toml_escape "$base_url")"
name = "$(gs_toml_escape "$display_name")"
api_backend = "$(gs_toml_escape "$api_backend")"
EOF
  chmod 600 "$profile_file" 2>/dev/null || true

  if [ "$keep_existing" != "true" ]; then
    printf '%s\n' "$token" > "$secret_file"
    chmod 600 "$secret_file" 2>/dev/null || true
  fi

  gs_apply_profile_to_config "$name" || return "$?"

  echo "Saved profile: $name"
  echo "  model=$model  backend=$api_backend"
}

gs_use() {
  local name
  name="${1:-}"
  if [ -z "$name" ]; then
    gs_die "Usage: grok-switch use <profile>"
    return 1
  fi
  gs_validate_profile "$name" || return "$?"
  if [ ! -f "$(gs_profile_file "$name")" ]; then
    gs_die "Profile not found: $name"
    return 1
  fi

  gs_ensure_dirs
  gs_apply_profile_to_config "$name" || return "$?"
  printf '%s\n' "$name" > "$(gs_current_file)"
  chmod 600 "$(gs_current_file)" 2>/dev/null || true
  echo "Current profile: $name"
}

gs_list() {
  local dir current found file name mark secret_state nullglob_was_set
  dir="$(gs_profile_dir)"
  current="$(gs_current_name 2>/dev/null || true)"
  found="false"

  if shopt -q nullglob; then
    nullglob_was_set="0"
  else
    nullglob_was_set="1"
  fi
  shopt -s nullglob
  for file in "$dir"/*.toml; do
    found="true"
    name="${file##*/}"
    name="${name%.toml}"
    mark=" "
    [ "$name" = "$current" ] && mark="*"
    secret_state="no-token"
    [ -f "$(gs_secret_file "$name")" ] && secret_state="token"
    printf '%s %-24s %s\n' "$mark" "$name" "$secret_state"
  done

  if [ "$found" != "true" ]; then
    echo "No profiles found. Run: gxadd"
  fi

  [ "$nullglob_was_set" -eq 0 ] || shopt -u nullglob
}

gs_which() {
  local current
  current="$(gs_current_name 2>/dev/null || true)"
  if [ -n "$current" ]; then
    echo "$current"
  else
    echo "No current profile. Grok will use $(gs_config_file) as-is."
  fi
}

gs_load_secret() {
  local name secret_file
  name="$1"
  secret_file="$(gs_secret_file "$name")"

  gs_validate_profile "$name" || return "$?"
  if [ ! -f "$secret_file" ]; then
    gs_die "API key file not found for profile: $name"
    return 1
  fi
  unset GROK_SWITCH_API_KEY
  IFS= read -r GROK_SWITCH_API_KEY < "$secret_file" || true
  if [[ "$GROK_SWITCH_API_KEY" == export\ GROK_SWITCH_API_KEY=* ]]; then
    gs_die "API key file uses the old shell format. Re-run: gxadd $name"
    return 1
  fi
  if [ -z "${GROK_SWITCH_API_KEY:-}" ]; then
    gs_die "API key is empty for profile: $name"
    return 1
  fi
  export GROK_SWITCH_API_KEY
}

gs_selected_profile() {
  local profile

  if [ -n "${GROK_PROFILE:-}" ]; then
    profile="$GROK_PROFILE"
    gs_validate_profile "$profile" || return "$?"
    printf '%s\n' "$profile"
    return 0
  fi

  [ -f "$(gs_current_file)" ] || return 1
  gs_current_name
}

gs_run() {
  local profile status

  if profile="$(gs_selected_profile)"; then
    if [ ! -f "$(gs_profile_file "$profile")" ]; then
      gs_die "Profile not found: $profile"
      return 1
    fi
    (
      gs_load_secret "$profile" || exit "$?"
      gs_apply_profile_to_config "$profile" || exit "$?"
      command grok -m "$profile" "$@"
    )
  else
    status="$?"
    [ "$status" -eq 1 ] || return "$status"
    command grok "$@"
  fi
}

gs_exec() {
  # Headless helper: gxe "prompt"  or  gxe -p "prompt" / other grok flags
  if [ "$#" -eq 0 ]; then
    gs_run -p
    return "$?"
  fi
  if [[ "${1:-}" == -* ]]; then
    gs_run "$@"
    return "$?"
  fi
  gs_run -p "$*"
}

gs_remove() {
  local name current
  name="${1:-}"
  if [ -z "$name" ]; then
    gs_die "Usage: grok-switch remove <profile>"
    return 1
  fi
  gs_validate_profile "$name" || return "$?"

  rm -f "$(gs_profile_file "$name")" "$(gs_secret_file "$name")"
  if [ -f "$(gs_config_file)" ]; then
    gs_remove_toml_section "$(gs_config_file)" "[model.$name]"
  fi
  current="$(gs_current_name 2>/dev/null || true)"
  if [ "$current" = "$name" ]; then
    rm -f "$(gs_current_file)"
  fi
  echo "Removed profile: $name"
}

gs_init_config() {
  local config
  gs_ensure_dirs
  config="$(gs_config_file)"

  if [ -f "$config" ]; then
    echo "Kept existing config: $config"
    return 0
  fi

  cat > "$config" <<'EOF'
# Grok base config. Model endpoints are selected by grok-switch profiles.
[cli]
installer = "npm"
auto_update = true

[models]
# default is set by: grok-switch use <profile>

[ui]
permission_mode = "always-approve"
EOF
  chmod 600 "$config" 2>/dev/null || true
  echo "Created config: $config"
}

gs_install_shell() {
  local rc_file script_path
  script_path="${GROK_SWITCH_SCRIPT_PATH:-$(gs_script_path)}"
  rc_file="${1:-${GROK_SWITCH_RC_FILE:-$HOME/.bashrc}}"

  touch "$rc_file"
  sed -i '/# >>> grok-switch >>>/,/# <<< grok-switch <<</d' "$rc_file"
  cat >> "$rc_file" <<EOF

# >>> grok-switch >>>
source "$script_path"
# <<< grok-switch <<<
EOF
  echo "Installed shell hook: $rc_file"
}

gs_uninstall_shell() {
  local rc_file
  rc_file="${1:-${GROK_SWITCH_RC_FILE:-$HOME/.bashrc}}"
  [ -f "$rc_file" ] || return 0
  sed -i '/# >>> grok-switch >>>/,/# <<< grok-switch <<</d' "$rc_file"
  echo "Removed shell hook: $rc_file"
}

gs_help() {
  cat <<'EOF'
grok-switch - Grok profile switcher

Usage:
  grok-switch add [name]       Add or update a profile
  grok-switch use <name>       Set current profile (writes ~/.grok/config.toml)
  grok-switch list             List profiles
  grok-switch current          Show current profile
  grok-switch run [args...]    Run grok with current profile
  grok-switch exec [args...]   Run grok headless (-p) with current profile
  grok-switch remove <name>    Remove a profile
  grok-switch init-config      Create base ~/.grok/config.toml if missing
  grok-switch install-shell    Add gx helpers to ~/.bashrc
  grok-switch uninstall-shell  Remove gx helpers from ~/.bashrc

Shell helpers after sourcing:
  gx [args...]          grok with current profile
  gxe [prompt|args...]  grok headless with current profile
  gxadd [name]          add/update profile
  gxuse <name>          switch profile
  gxlist                list profiles
  gxwhich               show current profile
  gxrm <name>           remove profile

Interactive add asks only:
  Profile name / Base URL / API Key
  (model=grok-4.5, backend=responses by default)

Optional advanced env for non-interactive add:
  GROK_SWITCH_PROFILE
  GROK_SWITCH_BASE_URL
  GROK_SWITCH_API_KEY / GROK_SWITCH_TOKEN
  GROK_SWITCH_API_KEY_FILE / GROK_SWITCH_TOKEN_FILE
  GROK_SWITCH_MODEL              (default: grok-4.5)
  GROK_SWITCH_API_BACKEND        (default: responses)
  GROK_SWITCH_DISPLAY_NAME
  GROK_SWITCH_ADVANCED=1         (also prompt model/backend/display)

Override current profile for one shot:
  GROK_PROFILE=proxy1 gx
EOF
}

gs_main() {
  local command_name
  command_name="${1:-help}"
  if [ "$#" -gt 0 ]; then
    shift
  fi

  case "$command_name" in
    add) gs_add "$@" ;;
    use|switch) gs_use "$@" ;;
    list|ls) gs_list "$@" ;;
    current|which) gs_which "$@" ;;
    run) gs_run "$@" ;;
    exec) gs_exec "$@" ;;
    remove|rm) gs_remove "$@" ;;
    init-config) gs_init_config "$@" ;;
    install-shell) gs_install_shell "$@" ;;
    uninstall-shell) gs_uninstall_shell "$@" ;;
    help|-h|--help) gs_help ;;
    *) gs_die "Unknown command: $command_name" ;;
  esac
}

if _gs_is_sourced; then
  grok-switch() { gs_main "$@"; }
  gx() { gs_main run "$@"; }
  gxe() { gs_main exec "$@"; }
  gxadd() { gs_main add "$@"; }
  gxuse() { gs_main use "$@"; }
  gxlist() { gs_main list "$@"; }
  gxwhich() { gs_main current "$@"; }
  gxrm() { gs_main remove "$@"; }
else
  gs_main "$@"
fi
