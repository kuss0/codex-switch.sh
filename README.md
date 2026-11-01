# codex-switch.sh

用于 Codex CLI 的多配置切换脚本。切换后直接运行 `codex` 即可，无需别名、`source`、`--profile` 或手动导出 API Key。

需要 Linux、Bash 4.3+，以及 Python 3.11+（旧版 Python 需安装 `tomli`，安装器会尝试通过系统包管理器安装）。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/kuss0/codex-switch.sh/main/install.sh | bash
source ~/.bashrc
```

`source` 仅用于启用可选的 `cx*` 快捷函数；切换配置后，普通 `codex` 命令不依赖这些函数。

本地安装：

```bash
git clone git@github.com:kuss0/codex-switch.sh.git
cd codex-switch.sh
bash install.sh
```

## 命令

不使用别名的完整流程：

```bash
~/.local/bin/codex-switch add proxy1
~/.local/bin/codex-switch use proxy1
codex
```

`add` 提示输入 Base URL、模型和 token；`use` 将其激活为默认配置。旧版本用户更新脚本后，需要重新执行一次 `use`，不需要重新输入已有 token。

可选快捷函数：

```bash
cxadd [name]
cxuse <name>
cxlist
cxwhich
cx
cxe "任务"
cxrm <name>
```

也可以直接使用 `codex-switch`：

```bash
codex-switch add proxy1
codex-switch use proxy1
codex-switch run
```

## 非交互配置

```bash
printf '%s\n' "$CODEX_TOKEN" > /tmp/codex-token
chmod 600 /tmp/codex-token
CODEX_SWITCH_PROFILE=proxy1 \
CODEX_SWITCH_BASE_URL=https://your-proxy.example/v1 \
CODEX_SWITCH_MODEL=gpt-5.5 \
CODEX_SWITCH_WIRE_API=responses \
CODEX_SWITCH_TOKEN_FILE=/tmp/codex-token \
bash install.sh
```

`use` 更新 `$CODEX_HOME/config.toml`（默认 `~/.codex/config.toml`）中的模型选择，并写入专用 provider：`requires_openai_auth = false` 和 `experimental_bearer_token`。这使原生 `codex` 能自行读取凭据，无需网页登录，也不会改写 `auth.json`。

token 会明文保存在权限为 `600` 的配置和独立 token 文件中，不要分享这些文件。首次切换前的主配置备份为 `config.toml.before-codex-switch`。已有 MCP、项目、沙箱等设置会保留；删除当前 profile 时恢复切换前的模型选择。

profile 文件仍使用环境认证，便于显式 `--profile` 的 `cx`/`cxe` 兼容入口。直接运行 `codex --profile 名称` 会覆盖默认选择，通常应只运行 `codex`。

`ai-switch` 和 `asstatus` 仍保留为兼容入口，但只管理 Codex。

## 卸载

```bash
bash uninstall.sh
```

默认保留 Codex profile 和 token；彻底删除切换器数据及旧 Grok 数据：

```bash
bash uninstall.sh --purge-data
```

卸载切换器不会删除 Codex 主配置或其中的已激活凭据。需要撤销当前选择时，先执行 `codex-switch remove 名称`。

## 验证

```bash
python3 -m unittest -v test_switch.py
```

包含通过临时配置直接启动真实 `codex exec` 的本地 HTTP/SSE 测试，检查请求的模型与 Authorization；不使用真实密钥或外部模型服务。
