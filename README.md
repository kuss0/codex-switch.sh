# codex-switch.sh

用于新版 Codex CLI 的多配置切换脚本。每个 profile 保存独立的 Base URL、模型和 token，启动时通过 `OPENAI_API_KEY` 注入认证，避免新版 Codex 退回网页登录。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/kuss0/codex-switch.sh/main/install.sh | bash
source ~/.bashrc
```

本地安装：

```bash
git clone git@github.com:kuss0/codex-switch.sh.git
cd codex-switch.sh
bash install.sh
```

## 命令

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

profile 使用 `requires_openai_auth = false` 和 `env_key = "OPENAI_API_KEY"`。脚本只在启动 Codex 的子进程中设置变量，token 文件权限为 `600`。

`ai-switch` 和 `asstatus` 仍保留为兼容入口，但只管理 Codex。

## 卸载

```bash
bash uninstall.sh
```

默认保留 Codex profile 和 token；彻底删除切换器数据及旧 Grok 数据：

```bash
bash uninstall.sh --purge-data
```
