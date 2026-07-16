#!/bin/bash

set -euo pipefail

TOOL_VERSION="1.0.0"
TARGET_CLI_VERSION="0.144.2"
TARGET_ARCH="arm64"
PATCHED_BINARY_SHA256="4074160e8c1b1157ba922dc3cfc9374a59976160e4e8cfc62f13c0ae0acfe226"
BINARY_ARCHIVE_SHA256="4419da981733e344b4da1fe57f5e25462bdaaefd841ff76ca12c78de8f13cffc"
BINARY_ASSET_NAME="codex-${TARGET_CLI_VERSION}-aarch64-apple-darwin.gz"
BINARY_ASSET_URL="https://github.com/aluan/codex-fix-patch/releases/download/v${TOOL_VERSION}/${BINARY_ASSET_NAME}"
LAUNCH_AGENT_LABEL="com.local.codex-imagegen-patch"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGED_BINARY="$SCRIPT_DIR/bin/codex"
CACHE_DIR="${CODEX_IMAGEGEN_PATCH_CACHE:-$HOME/Library/Caches/codex-imagegen-patch}"
INSTALL_ROOT="${CODEX_IMAGEGEN_PATCH_ROOT:-$HOME/.local/share/codex-imagegen-patch}"
INSTALL_DIR="$INSTALL_ROOT/$TARGET_CLI_VERSION"
INSTALLED_BINARY="$INSTALL_DIR/codex"
LAUNCH_AGENT_PATH="$HOME/Library/LaunchAgents/$LAUNCH_AGENT_LABEL.plist"
LAUNCHER_DIR="$HOME/Applications"
LAUNCHER_PATH="$LAUNCHER_DIR/Launch ChatGPT with ImageGen Patch.command"
APP_PATH="${CODEX_IMAGEGEN_APP_PATH:-}"
ACTION="install"
DRY_RUN=0
ASSUME_YES=0
TEST_IMAGE=0
TEMP_DIR=""

log() {
  printf '[codex-imagegen-patch] %s\n' "$*"
}

warn() {
  printf '[codex-imagegen-patch] 警告：%s\n' "$*" >&2
}

die() {
  printf '[codex-imagegen-patch] 错误：%s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Codex Latest ImageGen Patch $TOOL_VERSION

为最新版 ChatGPT/Codex App 恢复第三方中转站 Responses 托管生图。
不修改 App Bundle，不安装第二个 App。

用法：
  $(basename "$0") [选项]

选项：
  --yes              跳过安装确认
  --dry-run          仅检查并显示将执行的操作
  --test-image       安装后执行最小生图测试，可能消耗额度
  --app PATH         指定 ChatGPT/Codex App 路径
  --status           查看补丁和版本状态
  --uninstall        卸载补丁并恢复默认后端
  -h, --help         显示帮助
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --test-image)
      TEST_IMAGE=1
      shift
      ;;
    --app)
      [ "$#" -ge 2 ] || die "--app 缺少路径"
      APP_PATH="$2"
      shift 2
      ;;
    --status)
      ACTION="status"
      shift
      ;;
    --uninstall)
      ACTION="uninstall"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac
done

require_macos_arm64() {
  [ "$(uname -s)" = "Darwin" ] || die "当前工具仅支持 macOS"
  [ "$(uname -m)" = "$TARGET_ARCH" ] || die "当前补丁仅支持 Apple Silicon (arm64)"
}

require_commands() {
  local command_name
  for command_name in awk codesign curl gzip install launchctl open osascript plutil ps shasum xattr; do
    command -v "$command_name" >/dev/null 2>&1 || die "缺少系统命令：$command_name"
  done
}

cleanup() {
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
  fi
}

trap cleanup EXIT

find_app() {
  if [ -n "$APP_PATH" ]; then
    [ -d "$APP_PATH" ] || die "未找到指定 App：$APP_PATH"
    return
  fi
  local candidate
  for candidate in \
    "/Applications/ChatGPT.app" \
    "/Applications/Codex.app" \
    "$HOME/Applications/ChatGPT.app" \
    "$HOME/Applications/Codex.app"; do
    if [ -d "$candidate" ]; then
      APP_PATH="$candidate"
      return
    fi
  done
  die "未找到 ChatGPT/Codex App，可用 --app PATH 指定"
}

bundled_cli_path() {
  printf '%s/Contents/Resources/codex' "$APP_PATH"
}

cli_version() {
  local binary="$1"
  "$binary" --version 2>/dev/null | awk '{print $2}'
}

verify_app() {
  local app_cli
  local actual_version
  app_cli="$(bundled_cli_path)"
  [ -x "$app_cli" ] || die "App 未包含可执行 Codex CLI：$app_cli"
  codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1 || die "App 代码签名校验失败"
  actual_version="$(cli_version "$app_cli")"
  [ "$actual_version" = "$TARGET_CLI_VERSION" ] || die "App 内置 CLI 为 $actual_version，补丁目标为 $TARGET_CLI_VERSION；请使用对应版本补丁"
}

file_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

prepare_packaged_binary() {
  if [ -x "$PACKAGED_BINARY" ]; then
    return
  fi

  local archive_path="$CACHE_DIR/$BINARY_ASSET_NAME"
  mkdir -p "$CACHE_DIR"
  if [ ! -f "$archive_path" ] || [ "$(file_sha256 "$archive_path")" != "$BINARY_ARCHIVE_SHA256" ]; then
    rm -f "$archive_path"
    log "正在从 GitHub Release 下载补丁后端"
    curl -fL --retry 3 --retry-delay 2 --progress-bar "$BINARY_ASSET_URL" -o "$archive_path"
  fi
  [ "$(file_sha256 "$archive_path")" = "$BINARY_ARCHIVE_SHA256" ] || die "下载资源 SHA-256 校验失败"

  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-imagegen-patch.XXXXXX")"
  PACKAGED_BINARY="$TEMP_DIR/codex"
  gzip -dc "$archive_path" > "$PACKAGED_BINARY"
  chmod 755 "$PACKAGED_BINARY"
}

verify_packaged_binary() {
  local actual_hash
  [ -x "$PACKAGED_BINARY" ] || die "补丁包缺少可执行文件：$PACKAGED_BINARY"
  [ "$PATCHED_BINARY_SHA256" != "__PATCHED_SHA256__" ] || die "补丁包尚未写入二进制校验值"
  actual_hash="$(file_sha256 "$PACKAGED_BINARY")"
  [ "$actual_hash" = "$PATCHED_BINARY_SHA256" ] || die "补丁二进制 SHA-256 校验失败"
  [ "$(cli_version "$PACKAGED_BINARY")" = "$TARGET_CLI_VERSION" ] || die "补丁二进制版本不匹配"
  codesign --verify --strict "$PACKAGED_BINARY" >/dev/null 2>&1 || die "补丁二进制签名校验失败"
}

is_app_running() {
  ps -axo command= | awk -v prefix="$APP_PATH/Contents/MacOS/" '
    index($0, prefix) == 1 { found = 1 }
    END { exit !found }
  '
}

confirm_install() {
  [ "$ASSUME_YES" -eq 1 ] && return
  [ -t 0 ] || die "非交互运行请添加 --yes"
  cat <<EOF

即将执行：
  1. 校验 App 签名、CLI 版本和补丁 SHA-256
  2. 安装外置后端到：$INSTALLED_BINARY
  3. 设置 CODEX_CLI_PATH，不修改 App Bundle
  4. 创建登录自动激活项和备用启动器

继续？[y/N]
EOF
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) die "已取消" ;;
  esac
}

install_binary() {
  mkdir -p "$INSTALL_DIR"
  chmod 700 "$INSTALL_ROOT" "$INSTALL_DIR"
  install -m 755 "$PACKAGED_BINARY" "$INSTALLED_BINARY"
  xattr -d com.apple.quarantine "$INSTALLED_BINARY" 2>/dev/null || true
  [ "$(file_sha256 "$INSTALLED_BINARY")" = "$PATCHED_BINARY_SHA256" ] || die "安装后的二进制校验失败"
}

install_launch_agent() {
  mkdir -p "$(dirname "$LAUNCH_AGENT_PATH")"
  rm -f "$LAUNCH_AGENT_PATH"
  plutil -create xml1 "$LAUNCH_AGENT_PATH"
  plutil -insert Label -string "$LAUNCH_AGENT_LABEL" "$LAUNCH_AGENT_PATH"
  plutil -insert ProgramArguments -xml '<array/>' "$LAUNCH_AGENT_PATH"
  plutil -insert ProgramArguments.0 -string /bin/launchctl "$LAUNCH_AGENT_PATH"
  plutil -insert ProgramArguments.1 -string setenv "$LAUNCH_AGENT_PATH"
  plutil -insert ProgramArguments.2 -string CODEX_CLI_PATH "$LAUNCH_AGENT_PATH"
  plutil -insert ProgramArguments.3 -string "$INSTALLED_BINARY" "$LAUNCH_AGENT_PATH"
  plutil -insert RunAtLoad -bool true "$LAUNCH_AGENT_PATH"
  plutil -lint "$LAUNCH_AGENT_PATH" >/dev/null
  launchctl bootout "gui/$(id -u)/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PATH"
  launchctl setenv CODEX_CLI_PATH "$INSTALLED_BINARY"
}

create_launcher() {
  local quoted_app
  local quoted_binary
  quoted_app="$(printf '%q' "$APP_PATH")"
  quoted_binary="$(printf '%q' "$INSTALLED_BINARY")"
  mkdir -p "$LAUNCHER_DIR"
  cat > "$LAUNCHER_PATH" <<EOF
#!/bin/zsh
set -eu
app_path=$quoted_app
patched_cli=$quoted_binary
if ps -axo command= | awk -v prefix="\$app_path/Contents/MacOS/" 'index(\$0, prefix) == 1 { found = 1 } END { exit !found }'; then
  osascript -e 'display dialog "请先按 Command+Q 完全退出 ChatGPT/Codex，再使用补丁启动器。" buttons {"好"} default button "好" with icon caution'
  exit 1
fi
open -na "\$app_path" --env "CODEX_CLI_PATH=\$patched_cli"
EOF
  chmod 755 "$LAUNCHER_PATH"
}

print_status() {
  local app_version="未找到"
  local installed_version="未安装"
  local installed_hash="未安装"
  local active_path
  find_app
  if [ -x "$(bundled_cli_path)" ]; then
    app_version="$(cli_version "$(bundled_cli_path)")"
  fi
  if [ -x "$INSTALLED_BINARY" ]; then
    installed_version="$(cli_version "$INSTALLED_BINARY")"
    installed_hash="$(file_sha256 "$INSTALLED_BINARY")"
  fi
  active_path="$(launchctl getenv CODEX_CLI_PATH 2>/dev/null || true)"
  cat <<EOF
App:                 $APP_PATH
App CLI:             $app_version
补丁目标 CLI:        $TARGET_CLI_VERSION
补丁路径:            $INSTALLED_BINARY
已安装补丁 CLI:      $installed_version
已安装 SHA-256:      $installed_hash
当前 CODEX_CLI_PATH: ${active_path:-未设置}
LaunchAgent:         $LAUNCH_AGENT_PATH
备用启动器:          $LAUNCHER_PATH
EOF
  if [ "$app_version" != "$TARGET_CLI_VERSION" ]; then
    warn "App CLI 与补丁版本不一致"
    return 2
  fi
  if [ "$installed_hash" != "$PATCHED_BINARY_SHA256" ] || [ "$active_path" != "$INSTALLED_BINARY" ]; then
    warn "补丁未安装、未激活或校验不一致"
    return 1
  fi
  log "补丁状态正常"
}

run_image_test() {
  [ "$TEST_IMAGE" -eq 1 ] || return
  log "开始最小生图测试；此操作可能消耗中转站额度"
  "$INSTALLED_BINARY" exec \
    --ephemeral \
    --skip-git-repo-check \
    -C "$HOME" \
    '请使用 Responses 内置 image_generation 工具生成一张最小测试图：白色正方形背景中央一个蓝色实心圆，无文字。成功后只回复保存路径。'
}

uninstall_patch() {
  if is_app_running; then
    warn "ChatGPT/Codex 正在运行；卸载后请完全退出并重新打开"
  fi
  launchctl bootout "gui/$(id -u)/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
  launchctl unsetenv CODEX_CLI_PATH >/dev/null 2>&1 || true
  rm -f "$LAUNCH_AGENT_PATH" "$LAUNCHER_PATH"
  if [ -d "$INSTALL_ROOT" ]; then
    case "$INSTALL_ROOT" in
      "$HOME/.local/share/codex-imagegen-patch"|"$HOME/Library/Application Support/codex-imagegen-patch")
        rm -rf "$INSTALL_ROOT"
        ;;
      *)
        warn "自定义安装目录未自动删除：$INSTALL_ROOT"
        ;;
    esac
  fi
  log "补丁已卸载，已恢复 App 内置后端"
}

require_macos_arm64
require_commands

case "$ACTION" in
  status)
    print_status
    ;;
  uninstall)
    find_app
    uninstall_patch
    ;;
  install)
    find_app
    verify_app
    prepare_packaged_binary
    verify_packaged_binary
    confirm_install
    if [ "$DRY_RUN" -eq 1 ]; then
      log "检查通过；dry-run 未修改系统"
      exit 0
    fi
    install_binary
    install_launch_agent
    create_launcher
    log "补丁已安装并激活"
    if is_app_running; then
      warn "当前 App 仍在运行；请按 Command+Q 完全退出后重新打开"
    else
      log "现在可以从 Dock 正常打开 ChatGPT，或使用备用启动器"
    fi
    run_image_test
    ;;
esac
