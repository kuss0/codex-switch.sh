# codex-switch.sh

Codex 多配置切换脚本。它基于 Codex 原生 `--profile` 机制，不反复覆盖 `~/.codex/config.toml`，适合同时保存多个中转站、多个模型或多个 key。

## 功能

- 只配置 Codex，不包含 Claude。
- 支持多个 profile：`proxy1`、`backup`、`fast` 等。
- URL、模型、wire API、token 都可以按 profile 单独保存。
- token 单独保存在 `~/.codex/profile-secrets/*.env`，不会写进仓库。
- 提供一键安装脚本，也提供可维护的代码版脚本。

## 一键安装版

使用 `curl`：

```bash
curl -fsSL https://raw.githubusercontent.com/kuss0/codex-switch.sh/main/install.sh | bash
```

使用 `wget`：

```bash
wget -qO- https://raw.githubusercontent.com/kuss0/codex-switch.sh/main/install.sh | bash
```

安装完成后打开新终端，或执行：

```bash
source ~/.bashrc
```

## 代码版

走 SSH 克隆：

```bash
git clone git@github.com:kuss0/codex-switch.sh.git
cd codex-switch.sh
bash install.sh
```

只想加载切换功能，不安装 Node/Codex：

```bash
source ./codex-switch.sh
cxadd
cxuse default
cx
```

也可以直接执行脚本：

```bash
./codex-switch.sh add proxy1
./codex-switch.sh use proxy1
./codex-switch.sh run
```

## 常用命令

```bash
cx                  # 用当前 profile 启动 Codex
cxe "任务内容"       # 用当前 profile 跑 codex exec
cxadd              # 新增或更新 profile
cxuse proxy1       # 切换当前 profile
cxlist             # 查看所有 profile
cxwhich            # 查看当前 profile
cxrm proxy1        # 删除 profile
```

对应的完整命令也可以这样写：

```bash
codex-switch add proxy1
codex-switch use proxy1
codex-switch list
codex-switch run
```

## 新增配置示例

```bash
cxadd proxy1
```

按提示输入：

```text
Base URL: https://your-proxy.example/v1
Model [gpt-5.5]: gpt-5.5
Wire API [responses]: responses
Token:
```

切换并启动：

```bash
cxuse proxy1
cx
```

## 非交互安装

可以通过环境变量直接创建 profile。为了避免 token 进入 shell 历史，推荐从文件读取 token：

```bash
read -rsp "Token: " CODEX_TOKEN
printf '\n'
printf '%s\n' "$CODEX_TOKEN" > /tmp/codex-token
chmod 600 /tmp/codex-token

CODEX_SWITCH_PROFILE=proxy1 \
CODEX_SWITCH_BASE_URL=https://your-proxy.example/v1 \
CODEX_SWITCH_MODEL=gpt-5.5 \
CODEX_SWITCH_WIRE_API=responses \
CODEX_SWITCH_TOKEN_FILE=/tmp/codex-token \
bash install.sh
```

远程一键非交互时，同样先准备 `/tmp/codex-token`，再执行：

```bash
CODEX_SWITCH_PROFILE=proxy1 \
CODEX_SWITCH_BASE_URL=https://your-proxy.example/v1 \
CODEX_SWITCH_MODEL=gpt-5.5 \
CODEX_SWITCH_WIRE_API=responses \
CODEX_SWITCH_TOKEN_FILE=/tmp/codex-token \
bash <(curl -fsSL https://raw.githubusercontent.com/kuss0/codex-switch.sh/main/install.sh)
```

`CODEX_SWITCH_TOKEN='...'` 也支持，但只建议在 CI、临时容器或不会落入历史记录的环境里使用。

## 文件位置

```text
~/.codex/config.toml                    # Codex 基础配置
~/.codex/<profile>.config.toml          # Codex 原生 profile 文件
~/.codex/profile-secrets/<profile>.env  # 当前 profile 的 token
~/.codex/current-profile                # 当前默认 profile 名称
~/.codex/codex-switch.sh                # 已安装的切换脚本
~/.local/bin/codex-switch               # 命令入口符号链接
```

## 为什么这样做

Codex 支持 `--profile profile-name`，会读取：

```text
~/.codex/profile-name.config.toml
```

所以这个项目不会把多个配置硬塞进一个 `config.toml`，而是每个 profile 一个独立配置文件。`cx` 启动时会自动读取当前 profile 的 token，然后执行：

```bash
codex --profile 当前profile
```

## 安全说明

- 不要把 token 写进 README、issue、commit 或 shell 历史。
- token 文件默认在 `~/.codex/profile-secrets/`，权限会尽量设置为 `600`。
- `curl | bash` 方便但风险更高，介意的话先 `git clone` 后阅读脚本再运行。
- 删除配置用 `cxrm profile名`，会同时删除 profile 配置和对应 token 文件。

## 卸载 shell 快捷命令

```bash
codex-switch uninstall-shell
```

如需手动清理：

```bash
rm -f ~/.local/bin/codex-switch
rm -f ~/.codex/codex-switch.sh
```

profile 和 token 不会被上面的命令自动删除，需要时单独执行：

```bash
cxrm proxy1
```

## 排查

查看 Codex 是否安装：

```bash
command -v codex
codex --version
```

查看当前配置：

```bash
cxwhich
cxlist
```

如果 `cx` 命令不存在：

```bash
source ~/.bashrc
```

如果直接运行 `codex --profile proxy1` 报认证错误，通常是因为没有加载 token。请用：

```bash
cxuse proxy1
cx
```

或者先加载脚本：

```bash
source ~/.codex/codex-switch.sh
```
