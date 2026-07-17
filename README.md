# GPTSwitch

<p align="center">
  <img src="Brand/GPTSwitchLogo.png" alt="GPTSwitch Logo" width="180">
</p>

<p align="center">
  面向 macOS Codex App 的 Provider 管理、生图兼容、使用统计与界面换肤工具。
</p>

<p align="center">
  <a href="https://gptswitch-sq41818iem-88qgx8yuj6.preview.iga-pages.com/">官网</a> ·
  <a href="https://github.com/aluan/GPTSwitch/releases/latest">下载</a>
</p>

新版 Codex 使用独立的 Images API，部分第三方 Provider 只支持 Responses 托管的 `image_generation`，导致生图请求返回 `404`。GPTSwitch 在 Mac 本机启动原生 Swift 代理，自动完成两种协议之间的转换。

## 功能

- 将 `/images/generations`、`/images/edits` 转换为 Responses `image_generation`。
- 添加、检测、排序和快速切换多个第三方 Provider。
- 查看请求、Token、延迟与估算成本统计。
- 使用四款内置主题，或导入图片自动取色并自定义 Codex 界面。
- 停用代理时安全恢复原 Provider 地址。

## 安装

要求 macOS 14 或更高版本。

1. 从 [GitHub Releases](https://github.com/aluan/GPTSwitch/releases/latest) 下载 DMG 或 ZIP。
2. 将 `GPTSwitch.app` 拖入“应用程序”。
3. 从菜单栏打开主界面，添加 Provider 并点击“应用并启动”。
4. 完全退出并重新打开 Codex。

GPTSwitch 是菜单栏工具，不显示 Dock 图标。当前公开包使用 ad-hoc 签名；如果 macOS 阻止首次打开，可在 Finder 中右键选择“打开”，或运行：

```bash
xattr -dr com.apple.quarantine "/Applications/GPTSwitch.app"
open "/Applications/GPTSwitch.app"
```

## 工作原理

启用时，GPTSwitch 会备份 `~/.codex/config.toml`，只将当前 Provider 的 `base_url` 指向本机代理：

```text
Codex → 127.0.0.1:17891 → Provider
```

- `/responses`、`/models` 等普通请求透明转发。
- Images API 请求转换为 Responses 托管生图。
- 返回图片重新封装后交给 Codex 保存和展示。

Codex 升级后通常无需重新配置，因为 GPTSwitch 不替换 Codex CLI，也不修改 Codex.app。

## 安全与数据

- 代理只监听 `127.0.0.1`，不会暴露到局域网或公网。
- API Key 保存在 macOS 钥匙串，不写入数据库、日志或 Codex 配置。
- 统计仅记录 Provider、模型、状态码、Token 和耗时，不保存 Prompt 或响应正文。
- 换肤通过本机 CDP 应用，不修改 Codex 安装包或签名资源。

换肤使用未认证的本机 CDP 端口 `9341`；同一用户权限下的其他本机进程可能访问该端口。不使用主题时可点击“恢复原生界面”关闭此边界。

## 当前限制

- Provider 需支持 HTTP Responses API 和托管 `image_generation`。
- Responses WebSocket 不经过生图转换。
- `images/edits` 的能力取决于 Provider 实现。
- 换肤仅支持 macOS 版官方 Codex。
- 当前公开包尚未进行 Apple 公证。

## 开发

需要 Xcode 26+ 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

```bash
brew install xcodegen
./script/build_and_run.sh --verify
xcodebuild test \
  -project CodexImageGenProxy.xcodeproj \
  -scheme CodexImageGenProxy \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO
./script/package_app.sh
```

原生代码位于 `App/`，测试位于 `AppTests/`。Python 代理和命令行安装器仅作为旧版兼容后备。

## 相关项目

- [HeiGeAi/heige-codex-skin-studio](https://github.com/HeiGeAi/heige-codex-skin-studio)
- [OpenAI Codex PR #31596](https://github.com/openai/codex/pull/31596)
- [OpenAI Codex Issue #30921](https://github.com/openai/codex/issues/30921)

本项目采用 [MIT License](LICENSE)。
