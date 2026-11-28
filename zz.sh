#!/usr/bin/env bash
# Short, standalone tmux entry point; no shell function or alias is required.
set -euo pipefail

zz_help() {
    printf '%s\n' 'zz            进入/恢复会话；多个会话时选择，无会话时启动 Codex' \
        'zz 工作名     进入或新建指定会话' 'zz ls         列出会话' \
        'zz stop 名称  确认后结束指定会话及其中任务' \
        'zz reload     加载内置 tmux 配置到运行中的服务器' \
        '鼠标点窗口名   切换窗口' \
        'F12           返回 SSH，Codex 留在后台' \
        'Ctrl+b 然后 [ 回滚历史；q 或 Esc 返回'
}

case ${1:-} in
    -h|--help|help) zz_help; exit 0 ;;
esac
if ! command -v tmux >/dev/null 2>&1; then
    printf '%s\n' 'tmux 是可选组件，尚未安装。运行 codex-switch tmux-install 安装，或直接使用 codex。' >&2
    exit 1
fi

src=${BASH_SOURCE[0]}
while [[ -L $src ]]; do
    dir=$(cd "$(dirname "$src")" && pwd -P)
    src=$(readlink "$src")
    [[ $src = /* ]] || src=$dir/$src
done
config=$(cd "$(dirname "$src")" && pwd -P)/tmux.conf
[[ -f $config ]] || { printf '%s\n' '缺少 tmux.conf，请重新安装 codex-switch。' >&2; exit 1; }

zz_tmux() { command tmux -f "$config" "$@"; }
zz_valid_name() { [[ ${1:-} =~ ^[[:alnum:]_-]+$ ]]; }

case ${1:-} in
    reload)
        (( $# == 1 )) || { zz_help >&2; exit 2; }
        if ! zz_tmux -N has-session 2>/dev/null; then
            printf '%s\n' '当前没有运行中的 tmux 会话，下次 zz 会自动加载内置配置。'
            exit 0
        fi
        zz_tmux -N source-file "$config"
        printf '%s\n' '已加载内置 tmux 配置，窗口状态栏和鼠标点选已启用。'
        exit 0
        ;;
    ls|list)
        (( $# == 1 )) || { zz_help >&2; exit 2; }
        if ! zz_tmux list-sessions; then exit 1; fi
        exit 0
        ;;
    stop)
        if (( $# != 2 )) || ! zz_valid_name "$2"; then zz_help >&2; exit 2; fi
        zz_tmux has-session -t "=$2" || exit 1
        if ! read -r -p "结束会话 $2 及其中任务？[y/N]: " answer </dev/tty; then exit 1; fi
        case $answer in
            y|Y) zz_tmux kill-session -t "=$2" ;;
            *) printf '%s\n' '已取消。' ;;
        esac
        exit 0
        ;;
esac
if (( $# > 1 )); then zz_help >&2; exit 2; fi

session=${1:-}
if [[ -z $session && -n ${TMUX:-} ]]; then
    printf '当前已在 tmux 会话：%s\n' "$(zz_tmux display-message -p '#S')"
    exit 0
fi
if [[ -z $session ]]; then
    mapfile -t sessions < <(zz_tmux list-sessions -F '#S' 2>/dev/null || true)
    case ${#sessions[@]} in
        0) session=codex ;;
        1) session=${sessions[0]} ;;
        *)
            printf '%s\n' '选择要恢复的会话：'
            for i in "${!sessions[@]}"; do
                printf '%d) %s\n' "$((i + 1))" "${sessions[i]}"
            done
            if ! read -r -p '输入序号，或输入新会话名：' choice </dev/tty; then exit 1; fi
            if [[ $choice =~ ^[0-9]+$ ]]; then
                if (( ${#choice} > 8 )); then exit 2; fi
                index=$((10#$choice - 1))
                if (( index < 0 || index >= ${#sessions[@]} )); then
                    printf '%s\n' '无效序号。' >&2
                    exit 2
                fi
                session=${sessions[index]}
            else
                session=$choice
            fi
            ;;
    esac
fi
if ! zz_valid_name "$session"; then
    printf '%s\n' '会话名请使用字母、数字、下划线或短横线。' >&2
    exit 2
fi

if ! zz_tmux has-session -t "=$session" 2>/dev/null; then
    codex_bin=$(command -v codex) || { printf '%s\n' '未找到 Codex CLI。' >&2; exit 1; }
    # Capture duplicate-creation errors: two reconnects must never spawn two tasks.
    if ! error=$(zz_tmux new-session -d -s "$session" env "PATH=$PATH" "$codex_bin" 2>&1); then
        if ! zz_tmux has-session -t "=$session" 2>/dev/null; then
            printf '%s\n' "$error" >&2
            exit 1
        fi
    fi
fi
# Add the shortcut on existing servers only when the key is free.
if ! zz_tmux list-keys -T root F12 >/dev/null 2>&1; then
    zz_tmux bind-key -n F12 detach-client
fi
if [[ -n ${TMUX:-} ]]; then
    exec tmux -f "$config" switch-client -t "=$session"
fi
exec tmux -f "$config" attach-session -t "=$session"
