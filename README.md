# Codex ImageGen Compatibility Proxy

面向 macOS ChatGPT/Codex App 与第三方 Responses API 中转站的版本无关生图兼容工具。

最新版 App 会通过独立 Images API 调用 `POST /images/generations`，部分中转站只支持 Responses API 托管 `image_generation`，因此返回 `404`。本工具在本机启动一个仅监听 `127.0.0.1` 的轻量代理：

- 普通 `/responses`、`/models` 等请求透明转发到原中转站。
- `/images/generations` 和 `/images/edits` 转换为 Responses 托管 `image_generation` 调用。
- 将托管调用返回的图片重新封装为 Images API 响应，由 App 自带 CLI 按官方流程保存和展示。
- 不替换 App CLI，不修改 App Bundle，不受 App CLI 版本升级影响。

## 一键安装

推荐从 [GitHub Releases](https://github.com/aluan/codex-fix-patch/releases/latest) 下载 ZIP，解压后双击：

```text
Install Codex ImageGen Patch.command
```

也可以在终端运行：

```bash
./install-codex-imagegen-patch.sh
```

安装完成后按 `Command + Q` 完全退出 ChatGPT/Codex，再重新打开。无需重启电脑。

## App 升级

App 升级后不需要同步下载新补丁。本工具不再通过 `CODEX_CLI_PATH` 替换 CLI，App 始终使用自己携带的最新版后端；本地代理只处理稳定的 HTTP API 协议。

如果未来 OpenAI 修改 Images API 或 Responses `image_generation` 协议，才需要更新本工具。

## 常用命令

```bash
./install-codex-imagegen-patch.sh --status
./install-codex-imagegen-patch.sh --test-image
./install-codex-imagegen-patch.sh --uninstall
./install-codex-imagegen-patch.sh --dry-run
```

可选参数：

```bash
./install-codex-imagegen-patch.sh --port 17891
./install-codex-imagegen-patch.sh --bridge-model gpt-5.5
```

默认使用 `~/.codex/config.toml` 顶层的 `model` 作为生图桥接模型。`--test-image` 会真实调用中转站并可能消耗额度。

## 安装行为

安装器会：

1. 读取当前 `model_provider`、模型和对应的 `base_url`。
2. 创建带时间戳的 `config.toml` 备份。
3. 将当前 Provider 的 `base_url` 改为同路径的本地地址，例如 `http://127.0.0.1:17891/api`。
4. 创建 LaunchAgent，在登录后自动启动兼容代理。
5. 清除旧版补丁留下的 `CODEX_CLI_PATH`。

状态文件位于：

```text
~/.local/share/codex-imagegen-patch/state.json
```

状态文件只包含 Provider 名称、原始上游地址、桥接模型和端口，不包含 API Token。卸载时仅当当前 `base_url` 仍指向本代理才自动恢复，避免覆盖用户之后的手工配置。

## 安全说明

- 代理固定绑定 `127.0.0.1`，不会监听局域网或公网地址。
- Token 仍由 Codex 管理；代理只转发请求携带的认证头，不保存、不打印请求头和正文。
- 上游 HTTPS 证书使用 Python 标准库默认验证。
- 安装失败或代理健康检查失败时，安装器会尝试恢复原始 `base_url`。
- App Bundle、Apple 签名和自动更新保持不变。

## 当前限制

- 支持 JSON/SSE 形式的 Responses HTTP API。
- 不代理 Responses WebSocket；当前中转站需支持 Codex 的 HTTP Responses 模式。
- `images/edits` 会把输入图片作为 Responses 输入图片转发，具体编辑能力取决于中转站实现。
- 当前安装器面向 macOS，并要求系统可用 Python 3。

## 开发与测试

项目只使用 Python 标准库：

```bash
/usr/bin/python3 -m unittest -v tests.test_proxy
bash -n install-codex-imagegen-patch.sh
```

代理实现位于 `proxy/codex_imagegen_proxy.py`。

## 相关上游

- [PR #31596: Use the image generation extension by default](https://github.com/openai/codex/pull/31596)
- [Issue #30921: Custom GPT endpoint cannot use Imagen](https://github.com/openai/codex/issues/30921)
