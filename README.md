# Codex Latest ImageGen Patch

面向 macOS Apple Silicon 的最新版 ChatGPT/Codex App 生图兼容补丁。

推荐从 [GitHub Releases](https://github.com/aluan/codex-fix-patch/releases/latest) 下载完整 ZIP；也可以克隆源码后直接运行安装器，安装器会自动下载并校验对应的补丁后端。

适用场景：自定义 Responses API 中转站可以处理 Responses 托管生图，但未实现新版独立 Images API，升级后生图请求变为 `POST /images/generations` 并返回 `404`。

## 工作原理

补丁不修改 `/Applications/ChatGPT.app`，也不重签 App。它通过最新版 App 官方保留的 `CODEX_CLI_PATH` 覆盖机制，加载一个与 App 内置 CLI 同版本的兼容后端：

- 官方 OpenAI Provider 仍使用新版独立 Images API。
- 自定义 Provider、自定义 `base_url` 或显式配置 `x-openai-actor-authorization` 的中转站恢复 Responses 托管 `image_generation` 工具。
- App UI、自动更新、Apple 签名和用户配置保持不变。

## 一键安装

双击：

```text
Install Codex ImageGen Patch.command
```

或在终端运行：

```bash
./install-codex-imagegen-patch.sh
```

从源码仓库安装：

```bash
git clone git@github.com:aluan/codex-fix-patch.git
cd codex-fix-patch
./install-codex-imagegen-patch.sh
```

安装后完全退出并重新打开 ChatGPT。安装器会创建登录时自动生效的 LaunchAgent，并提供一个备用启动器：

```text
~/Applications/Launch ChatGPT with ImageGen Patch.command
```

## 常用命令

```bash
./install-codex-imagegen-patch.sh --status
./install-codex-imagegen-patch.sh --test-image
./install-codex-imagegen-patch.sh --uninstall
./install-codex-imagegen-patch.sh --dry-run
```

`--test-image` 会真实调用当前中转站，可能消耗额度。安装和卸载不会读取、复制或输出 API Token。

## 兼容范围

- macOS Apple Silicon (`arm64`)
- ChatGPT/Codex App 内置 `codex-cli 0.144.2`
- 自定义 Provider 使用 Responses API
- Provider 请求头包含非空 `x-openai-actor-authorization`

`requires_openai_auth` 可以是 `true` 或 `false`，补丁兼容两种常见中转站认证方式。

App 升级并带来新的 CLI 版本后，请先运行 `--status`。版本不一致时应更新补丁，不要长期混用不同版本的 App UI 和后端协议。

## 安全与恢复

- 不修改 App Bundle，不破坏 OpenAI/Apple 签名。
- 补丁二进制有固定 SHA-256，安装前强制校验。
- SHA-256：`4074160e8c1b1157ba922dc3cfc9374a59976160e4e8cfc62f13c0ae0acfe226`
- 安装位置：`~/.local/share/codex-imagegen-patch/0.144.2/codex`
- 环境变量：`CODEX_CLI_PATH`
- `--uninstall` 会删除补丁、LaunchAgent 和备用启动器，并执行 `launchctl unsetenv CODEX_CLI_PATH`。

## 上游依据

- [PR #31596: Use the image generation extension by default](https://github.com/openai/codex/pull/31596)
- [Issue #30921: Custom GPT endpoint cannot use Imagen](https://github.com/openai/codex/issues/30921)

补丁源代码差异位于 `patches/codex-0.144.2-hosted-imagegen.patch`。
