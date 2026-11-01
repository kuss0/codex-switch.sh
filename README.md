# codex-switch.sh

直接维护 Codex 配置文件的 Bash 脚本。每套方案是一份完整的 `config.toml`，切换时先备份，再整体替换默认配置。直接运行 `codex` 即可，无需别名、环境变量、Python 或 `--profile`。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/kuss0/codex-switch.sh/main/install.sh | bash
```

## 配置并启动

直接运行即可打开 API 维护菜单：

```bash
~/.local/bin/codex-switch
```

选择 `1` 后输入配置名称、API 地址和 API Key。Key 隐藏输入，保存后立即启用。API 地址填写你自己的接口地址。

脚本不询问或指定模型，生成的配置不写 `model`，使用 Codex 原生默认模型。旧的 `CODEX_SWITCH_MODEL` 环境变量不再使用。

也可以直接进入 API 添加/修改流程：

```bash
~/.local/bin/codex-switch api default
# 输入 API 地址和 API Key；保存后立即启用
codex
```

旧版本用户更新脚本后，重新运行 `add 原名称`。API Key 留空可保留旧 token，不再使用旧的环境认证方案。

`api`、`add`、`edit` 是同一配置入口；不需要把 API Key 写在命令参数里。

## 管理完整配置

```bash
codex-switch list             # 列出方案
codex-switch use proxy2       # 备份并切换
codex-switch current          # 查看最后启用的方案
codex-switch save custom      # 保存当前 config.toml，含手工添加的 MCP 等设置
codex-switch restore          # 恢复首次切换前的完整配置
codex-switch remove proxy2    # 删除方案；若正在使用，先恢复原始配置
```

如果 `codex-switch` 不在 PATH 中，使用 `~/.local/bin/codex-switch`。`cx*` 函数和 `ai-switch` 是可选兼容入口。

## 文件和备份

- `$CODEX_HOME/config.toml`：Codex 实际读取的完整配置，默认目录为 `~/.codex`。
- `<名称>.config.toml`：保存的完整配置。
- `config-backups/`：每次替换前的完整配置备份。
- `config.toml.before-codex-switch`：首次切换前的配置；旧版已生成的同名备份会保留。
- `profile-secrets/<名称>.env`：保留 token，便于更新方案时留空沿用。

`add` 生成一份独立配置，使用 `requires_openai_auth = false` 和 `experimental_bearer_token`。API Key 明文保存在配置和 token 文件中，文件权限为 `600`，备份目录权限为 `700`。脚本不改写 `auth.json`。

**切换的是整份配置。** 新增方案不会自动合并旧配置的 MCP、项目或其他设置；旧内容在备份中。需要保留自定义设置时，编辑当前配置后执行 `save 名称`，以后使用 `use 名称` 切回。

## 非交互使用

```bash
CODEX_SWITCH_BASE_URL=https://your-proxy.example/v1 \
CODEX_SWITCH_TOKEN_FILE=/path/to/token \
~/.local/bin/codex-switch add default
codex
```

仅支持 `responses`，不再询问 Wire API。token 文件应只包含一行 API Key。

## 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/kuss0/codex-switch.sh/main/uninstall.sh | bash
```

默认只移除切换器和 shell hook，保留 Codex 配置、方案与备份。如果需要恢复原配置，在卸载前先执行 `codex-switch restore`。

## 验证

开发测试需要 Python 3.11+；安装和使用切换器无需 Python。

```bash
python3 -m unittest -v test_switch.py
```

测试通过临时配置直接启动真实 `codex exec`，由本地 HTTP/SSE 接口验证模型和认证，不使用真实密钥或外部模型服务。
