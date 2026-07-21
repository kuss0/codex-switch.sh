# ai-switch.sh

**Codex + Grok 二合一**多配置切换脚本。

- Codex 侧基于原生 `--profile`（同 [codex-switch.sh](https://github.com/kuss0/codex-switch.sh)）
- Grok 侧通过 `~/.grok/config.toml` 的 `[model.*]` + `env_key` 切换
- 一套安装、一个 shell hook，`cx*` / `gx*` 都能用

## 功能

- 同时管理 Codex、Grok 多中转 / 多模型 / 多 key
- token 单独落盘，不进 git
- 一键安装 Node、Codex CLI、Grok CLI、切换脚本

## 环境要求

- Linux + Bash 4.3+
- `curl` 或 `wget`
- 可安装 Node.js 20 与 npm 全局包

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/kuss0/codex-switch.sh/main/install.sh | bash
```

或：

```bash
wget -qO- https://raw.githubusercontent.com/kuss0/codex-switch.sh/main/install.sh | bash
```

装完后：

```bash
source ~/.bashrc
```

## 本地安装

```bash
git clone git@github.com:kuss0/codex-switch.sh.git
cd ai-switch.sh
bash install.sh
```

只加载切换功能（不装 CLI）：

```bash
source ./ai-switch.sh
cxlist
gxlist
asstatus
```

## 常用命令

### Codex

```bash
cx                  # 当前 profile 启动 Codex
cxe "任务"           # codex exec
cxadd              # 新增/更新 profile
cxuse proxy1       # 切换
cxlist
cxwhich
cxrm proxy1
```

### Grok

```bash
gx                  # 当前 profile 启动 Grok
gxe "任务"           # grok -p headless
gxadd              # 新增/更新 profile
gxuse proxy1
gxlist
gxwhich
gxrm proxy1
```

### 一起看

```bash
as / asstatus       # 两边状态
aslist              # 两边 profile 列表
ai-switch help
ai-switch codex list
ai-switch grok list
```

## 新增配置示例

### Codex

```bash
cxadd proxy1
# Base URL / Model / Wire API / Token
cxuse proxy1
cx
```

### Grok

```bash
gxadd proxy1
# Base URL / Model / API backend / Token
gxuse proxy1
gx
```

## 非交互安装

```bash
# Codex
printf '%s\n' "$CODEX_TOKEN" > /tmp/codex-token && chmod 600 /tmp/codex-token
# Grok
printf '%s\n' "$GROK_TOKEN" > /tmp/grok-token && chmod 600 /tmp/grok-token

CODEX_SWITCH_PROFILE=proxy1 \
CODEX_SWITCH_BASE_URL=https://your-proxy.example/v1 \
CODEX_SWITCH_MODEL=gpt-5.5 \
CODEX_SWITCH_WIRE_API=responses \
CODEX_SWITCH_TOKEN_FILE=/tmp/codex-token \
GROK_SWITCH_PROFILE=proxy1 \
GROK_SWITCH_BASE_URL=https://your-proxy.example/v1 \
GROK_SWITCH_MODEL=grok-4.5 \
GROK_SWITCH_API_BACKEND=responses \
GROK_SWITCH_TOKEN_FILE=/tmp/grok-token \
bash install.sh
```

跳过交互建 profile：

```bash
AI_SWITCH_SKIP_PROFILE=1 bash install.sh
```

## 文件位置

```text
~/.local/share/ai-switch/
  ai-switch.sh
  codex-switch.sh
  grok-switch.sh

~/.local/bin/ai-switch
~/.local/bin/codex-switch
~/.local/bin/grok-switch

~/.codex/config.toml
~/.codex/<profile>.config.toml
~/.codex/profile-secrets/<profile>.env
~/.codex/current-profile

~/.grok/config.toml
~/.grok/profiles/<profile>.toml
~/.grok/profile-secrets/<profile>.env
~/.grok/current-profile
```

## 原理简述

| | Codex | Grok |
|--|-------|------|
| 启动 | `codex --profile name` | `grok -m name` |
| profile 文件 | `~/.codex/name.config.toml` | `~/.grok/profiles/name.toml` |
| token | `CODEX_SWITCH_API_KEY` | `GROK_SWITCH_API_KEY` |
| 写入主配置 | 否（原生 profile） | 是（`[model.name]` + `default`） |

## 安全

- 不要把 token 写进 README / commit / shell 历史
- secret 文件权限尽量 `600`
- Grok 的 `config.toml` 只用 `env_key`，不落盘 token
- 介意 `curl | bash` 就先 clone 再读脚本

## 卸载 shell hook

```bash
ai-switch uninstall-shell
# 或
rm -f ~/.local/bin/ai-switch ~/.local/bin/codex-switch ~/.local/bin/grok-switch
rm -rf ~/.local/share/ai-switch
```

profile / token 需手动 `cxrm` / `gxrm`。

## 排查

```bash
command -v codex grok ai-switch
codex --version
grok --version
asstatus
source ~/.bashrc
```

直接 `codex --profile x` / `grok -m x` 若认证失败，用 `cx` / `gx` 启动（会加载 token）。
