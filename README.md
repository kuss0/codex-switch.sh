# codex-switch.sh

直接维护 Codex 配置文件的 Bash 脚本。每套方案是一份完整的 `config.toml`，切换时先备份，再整体替换默认配置。直接运行 `codex` 即可，无需别名、环境变量、Python 或 `--profile`。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/kuss0/codex-switch.sh/main/install.sh | bash
```

安装器使用当前 Node.js LTS，并从官方 npm 源安装 `@openai/codex@latest`，显示实际命令路径、版本和官方最新稳定版。重复运行可更新已安装的脚本。

只更新切换脚本和 `zz` 时，可以给安装器传入 `--switcher-only`。

**tmux 可选安装，默认不安装。** 交互时选择是否启用断线保活，也可之后运行 `codex-switch tmux-install`。跳过 tmux 后照常直接运行 `codex`。

## 配置并启动

直接运行即可打开 API 维护菜单：

```bash
~/.local/bin/codex-switch
```

选择 `1` 后输入配置名称、API 地址和 API Key。API 地址预填 `https://cpa.openi.eu.org/v1`，回车直接采用，也可以输入其他地址。Key **可见输入**，便于核对，保存后立即启用；编辑已有方案时 Key 留空保留原值。

脚本不询问或指定模型，生成的配置不写 `model`，使用 Codex 原生默认模型。旧的 `CODEX_SWITCH_MODEL` 环境变量不再使用。

也可以直接进入 API 添加/修改流程：

```bash
~/.local/bin/codex-switch api default
# 输入 API 地址和 API Key；保存后立即启用
codex
```

旧版本用户更新脚本后，重新运行 `add 原名称`。API Key 留空可保留旧 token，不再使用旧的环境认证方案。

`api`、`add`、`edit` 是同一配置入口；不需要把 API Key 写在命令参数里。

## 可选 tmux 保活

```bash
codex-switch tmux-install     # 之后补装；不会重复安装已有 tmux
zz                           # 启动或恢复；多个会话时按序号选择
zz work                      # 启动或恢复 work 会话
zz ls                        # 列出会话
zz stop work                 # 确认后结束 work 及其中任务
```

`zz` 是独立可执行入口，无需 shell 别名。第一次创建会话会在当前目录启动原生 Codex；重连只恢复原进程，不会重复启动。已经在 tmux 中时会切换会话，避免嵌套。

- **F12**：返回 SSH，Codex 留在后台；iPhone 可通过 Termius 功能键栏发送。
- 也可直接断开 SSH，再次连接后执行 `zz`。保活针对 SSH 断线，VPS 重启会结束进程。
- 鼠标滚动、拖选复制；复制使用 OSC 52，需要终端允许写入剪贴板。粘贴使用 Termius 自带功能。
- `Ctrl+b` 后按 `[` 回滚历史，方向键或 PageUp/PageDown 翻页，`q` 或 Esc 返回。

内置配置保留 100000 行历史，关闭状态栏，只保留必要按键。配置保存在切换器目录内，**不覆盖 `~/.tmux.conf`，安装或升级不重载已有 tmux 服务器**。新服务器加载内置配置。已有服务器保留原设置，通过 `zz` 进入时会在 F12 未绑定的情况下添加脱离键。

升级会清理 shell hook，并取消旧 Zellij 的 `zz/zl/zk` 别名和函数。已经打开的 Bash 不会自动重载：如果仍出现旧 Zellij 提示，执行一次 `source ~/.bashrc`，以后直接使用 `zz`。

## 检查和更新 Codex

```bash
codex-switch version         # 实际命令路径、当前版本、官方最新稳定版
codex-switch update          # 从官方 npm 源更新并核对实际版本
```

菜单同样提供检查和更新入口。更新安装包后，正在运行的 Codex 保留原进程和版本；本脚本不会重启任务。

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
CODEX_SWITCH_BASE_URL=https://cpa.openi.eu.org/v1 \
CODEX_SWITCH_TOKEN_FILE=/path/to/token \
~/.local/bin/codex-switch add default
codex
```

仅支持 `responses`，不再询问 Wire API。token 文件应只包含一行 API Key。

非交互安装默认跳过 tmux。显式启用可使用 `CODEX_SWITCH_INSTALL_TMUX=1 bash install.sh`，禁用可使用 `CODEX_SWITCH_INSTALL_TMUX=0`。这些选项不影响 API 配置；`AI_SWITCH_SKIP_PROFILE=1` 可跳过首次配置流程。

## 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/kuss0/codex-switch.sh/main/uninstall.sh | bash
```

默认只移除切换器和 shell hook，保留 Codex 配置、方案与备份。如果需要恢复原配置，在卸载前先执行 `codex-switch restore`。

同时移除 `zz` 和内置 tmux 配置，保留已安装的 tmux 和正在运行的会话。替换前已有的独立 `zz` 会备份到切换器目录的 `install-backups/`。

## 验证

开发测试需要 Python 3.11+；安装和使用切换器无需 Python。

```bash
python3 -m unittest -v test_switch.py test_tmux.py
```

测试通过临时配置直接启动真实 `codex exec`，由本地 HTTP/SSE 接口验证模型和认证，不使用真实密钥或外部模型服务。

tmux 测试使用独立 socket、临时 HOME 和模拟任务，验证 F12、中文输入、多行粘贴、断线重连、会话选择和卸载保留任务，不操作已有会话。
