#!/bin/bash

set -euo pipefail

TOOL_VERSION="1.1.0"
DEFAULT_PORT="17891"
LAUNCH_AGENT_LABEL="com.local.codex-imagegen-patch"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_PROXY="$SCRIPT_DIR/proxy/codex_imagegen_proxy.py"
INSTALL_ROOT="${CODEX_IMAGEGEN_PATCH_ROOT:-$HOME/.local/share/codex-imagegen-patch}"
INSTALL_DIR="$INSTALL_ROOT/$TOOL_VERSION"
INSTALLED_PROXY="$INSTALL_DIR/codex_imagegen_proxy.py"
STATE_PATH="$INSTALL_ROOT/state.json"
CODEX_CONFIG="${CODEX_IMAGEGEN_CONFIG:-$HOME/.codex/config.toml}"
PORT="${CODEX_IMAGEGEN_PROXY_PORT:-$DEFAULT_PORT}"
BRIDGE_MODEL="${CODEX_IMAGEGEN_BRIDGE_MODEL:-}"
LAUNCH_AGENT_PATH="$HOME/Library/LaunchAgents/$LAUNCH_AGENT_LABEL.plist"
LAUNCHER_DIR="$HOME/Applications"
LAUNCHER_PATH="$LAUNCHER_DIR/Launch ChatGPT with ImageGen Patch.command"
LOG_DIR="$HOME/Library/Logs/codex-imagegen-patch"
APP_PATH="${CODEX_IMAGEGEN_APP_PATH:-}"
PYTHON_BIN=""
ACTION="install"
DRY_RUN=0
ASSUME_YES=0
TEST_IMAGE=0

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
Codex ImageGen Compatibility Proxy $TOOL_VERSION

通过仅监听本机回环地址的 API 兼容代理，将新版 Images API 请求转换为
第三方中转站支持的 Responses 托管 image_generation 调用。

用法：
  $(basename "$0") [选项]

选项：
  --yes              跳过安装确认
  --dry-run          仅检查配置，不修改任何文件
  --test-image       安装后执行真实生图测试，可能消耗额度
  --app PATH         指定 ChatGPT/Codex App 路径
  --port PORT        指定本地代理端口，默认 $DEFAULT_PORT
  --bridge-model ID  指定执行 Responses 托管生图的模型
  --status           查看代理、配置和旧 CLI 覆盖状态
  --uninstall        停止代理并恢复原始中转站 base_url
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
    --port)
      [ "$#" -ge 2 ] || die "--port 缺少端口"
      PORT="$2"
      shift 2
      ;;
    --bridge-model)
      [ "$#" -ge 2 ] || die "--bridge-model 缺少模型 ID"
      BRIDGE_MODEL="$2"
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

require_macos() {
  [ "$(uname -s)" = "Darwin" ] || die "当前安装器仅支持 macOS"
}

find_python() {
  local candidate
  for candidate in /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if [ -x "$candidate" ]; then
      PYTHON_BIN="$candidate"
      return
    fi
  done
  command -v python3 >/dev/null 2>&1 || die "未找到 Python 3"
  PYTHON_BIN="$(command -v python3)"
}

require_commands() {
  local command_name
  for command_name in codesign curl install launchctl open osascript plutil ps; do
    command -v "$command_name" >/dev/null 2>&1 || die "缺少系统命令：$command_name"
  done
  find_python
}

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
  "$(bundled_cli_path)" --version 2>/dev/null | awk '{print $2}'
}

verify_app() {
  [ -x "$(bundled_cli_path)" ] || die "App 未包含可执行 Codex CLI"
  codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1 || die "App 代码签名校验失败"
}

verify_port() {
  case "$PORT" in
    ''|*[!0-9]*) die "代理端口必须是数字" ;;
  esac
  [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || die "代理端口必须在 1024 到 65535 之间"
}

inspect_configuration() {
  if [ -f "$STATE_PATH" ]; then
    if "$PYTHON_BIN" "$SOURCE_PROXY" config-status --state "$STATE_PATH" >/dev/null 2>&1; then
      "$PYTHON_BIN" "$SOURCE_PROXY" print-state --state "$STATE_PATH"
      return
    fi
    die "发现已有代理状态，但 Codex 配置与之不一致；请先运行 --uninstall"
  fi
  local args=(config-inspect --config "$CODEX_CONFIG" --port "$PORT")
  if [ -n "$BRIDGE_MODEL" ]; then
    args+=(--bridge-model "$BRIDGE_MODEL")
  fi
  "$PYTHON_BIN" "$SOURCE_PROXY" "${args[@]}"
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
  1. 备份 $CODEX_CONFIG
  2. 将当前 Provider 的 base_url 改为 http://127.0.0.1:$PORT
  3. 安装本地兼容代理并创建登录自动启动项
  4. 清除旧版 CODEX_CLI_PATH，继续使用 App 自带最新版 CLI

代理只监听 127.0.0.1，不保存 Token，不记录请求正文。
继续？[y/N]
EOF
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) die "已取消" ;;
  esac
}

install_proxy() {
  [ -f "$SOURCE_PROXY" ] || die "补丁包缺少代理程序：$SOURCE_PROXY"
  mkdir -p "$INSTALL_DIR"
  chmod 700 "$INSTALL_ROOT" "$INSTALL_DIR"
  install -m 755 "$SOURCE_PROXY" "$INSTALLED_PROXY"
  "$PYTHON_BIN" -m py_compile "$INSTALLED_PROXY"
}

configure_codex() {
  local args=(config-install --config "$CODEX_CONFIG" --state "$STATE_PATH" --port "$PORT")
  if [ -n "$BRIDGE_MODEL" ]; then
    args+=(--bridge-model "$BRIDGE_MODEL")
  fi
  "$PYTHON_BIN" "$INSTALLED_PROXY" "${args[@]}"
}

restore_codex_config() {
  local proxy="$INSTALLED_PROXY"
  [ -f "$proxy" ] || proxy="$SOURCE_PROXY"
  if [ -f "$proxy" ] && [ -f "$STATE_PATH" ]; then
    "$PYTHON_BIN" "$proxy" config-uninstall --state "$STATE_PATH"
  fi
}

install_launch_agent() {
  mkdir -p "$(dirname "$LAUNCH_AGENT_PATH")" "$LOG_DIR"
  rm -f "$LAUNCH_AGENT_PATH"
  plutil -create xml1 "$LAUNCH_AGENT_PATH"
  plutil -insert Label -string "$LAUNCH_AGENT_LABEL" "$LAUNCH_AGENT_PATH"
  plutil -insert ProgramArguments -xml '<array/>' "$LAUNCH_AGENT_PATH"
  plutil -insert ProgramArguments.0 -string "$PYTHON_BIN" "$LAUNCH_AGENT_PATH"
  plutil -insert ProgramArguments.1 -string "$INSTALLED_PROXY" "$LAUNCH_AGENT_PATH"
  plutil -insert ProgramArguments.2 -string serve "$LAUNCH_AGENT_PATH"
  plutil -insert ProgramArguments.3 -string --state "$LAUNCH_AGENT_PATH"
  plutil -insert ProgramArguments.4 -string "$STATE_PATH" "$LAUNCH_AGENT_PATH"
  plutil -insert RunAtLoad -bool true "$LAUNCH_AGENT_PATH"
  plutil -insert KeepAlive -bool true "$LAUNCH_AGENT_PATH"
  plutil -insert ProcessType -string Background "$LAUNCH_AGENT_PATH"
  plutil -insert StandardOutPath -string "$LOG_DIR/proxy.log" "$LAUNCH_AGENT_PATH"
  plutil -insert StandardErrorPath -string "$LOG_DIR/proxy.log" "$LAUNCH_AGENT_PATH"
  plutil -lint "$LAUNCH_AGENT_PATH" >/dev/null
  launchctl bootout "gui/$(id -u)/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PATH"
}

health_url() {
  printf 'http://127.0.0.1:%s/_codex_imagegen_patch/health' "$PORT"
}

wait_for_health() {
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS --max-time 2 "$(health_url)" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

create_launcher() {
  local quoted_app
  local quoted_health
  quoted_app="$(printf '%q' "$APP_PATH")"
  quoted_health="$(printf '%q' "$(health_url)")"
  mkdir -p "$LAUNCHER_DIR"
  cat > "$LAUNCHER_PATH" <<EOF
#!/bin/zsh
set -eu
app_path=$quoted_app
health_url=$quoted_health
if ! /usr/bin/curl -fsS --max-time 2 "\$health_url" >/dev/null; then
  /usr/bin/osascript -e 'display dialog "生图兼容代理尚未就绪，请运行安装器的 --status 检查。" buttons {"好"} default button "好" with icon caution'
  exit 1
fi
/usr/bin/open -a "\$app_path"
EOF
  chmod 755 "$LAUNCHER_PATH"
}

remove_legacy_cli_override() {
  launchctl unsetenv CODEX_CLI_PATH >/dev/null 2>&1 || true
}

remove_legacy_cli_payloads() {
  local legacy_dir
  for legacy_dir in "$INSTALL_ROOT"/0.*; do
    [ -d "$legacy_dir" ] || continue
    rm -rf "$legacy_dir"
  done
}

print_status() {
  local app_version="未找到"
  local active_cli_path
  local config_ok=0
  local proxy_ok=0
  if [ -f "$STATE_PATH" ]; then
    PORT="$("$PYTHON_BIN" - "$STATE_PATH" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["port"])
PY
)"
  fi
  find_app
  if [ -x "$(bundled_cli_path)" ]; then
    app_version="$(cli_version)"
  fi
  active_cli_path="$(launchctl getenv CODEX_CLI_PATH 2>/dev/null || true)"
  if [ -f "$INSTALLED_PROXY" ] && [ -f "$STATE_PATH" ]; then
    if "$PYTHON_BIN" "$INSTALLED_PROXY" config-status --state "$STATE_PATH" >/dev/null 2>&1; then
      config_ok=1
    fi
  fi
  if curl -fsS --max-time 2 "$(health_url)" >/dev/null 2>&1; then
    proxy_ok=1
  fi
  cat <<EOF
App:                 $APP_PATH
App CLI:             ${app_version}（不再绑定补丁版本）
代理版本:            $TOOL_VERSION
代理程序:            $INSTALLED_PROXY
代理状态:            $([ "$proxy_ok" -eq 1 ] && printf '正常' || printf '未运行')
Codex 配置:          $([ "$config_ok" -eq 1 ] && printf '已指向本地代理' || printf '未配置或不一致')
当前 CODEX_CLI_PATH: ${active_cli_path:-未设置（正确）}
LaunchAgent:         $LAUNCH_AGENT_PATH
状态文件:            $STATE_PATH
EOF
  if [ -n "$active_cli_path" ]; then
    warn "检测到旧版 CODEX_CLI_PATH；请重新运行安装器修复"
    return 1
  fi
  if [ "$config_ok" -ne 1 ] || [ "$proxy_ok" -ne 1 ]; then
    warn "代理未安装、未启动或配置不一致"
    return 1
  fi
  log "补丁状态正常；未来 App 升级无需同步 CLI 补丁"
}

run_image_test() {
  [ "$TEST_IMAGE" -eq 1 ] || return
  local output_dir="$HOME/.codex/generated_images/proxy-self-test"
  local generated="$output_dir/test-$(date +%Y%m%d-%H%M%S).png"
  log "开始真实生图测试；此操作可能消耗中转站额度"
  if ! "$PYTHON_BIN" "$INSTALLED_PROXY" self-test --state "$STATE_PATH" --output "$generated" >/dev/null; then
    warn "代理真实生图自检失败"
    return 1
  fi
  [ -s "$generated" ] || die "自检未生成本地 PNG"
  log "真实生图测试通过：$generated"
}

uninstall_patch() {
  if is_app_running; then
    warn "ChatGPT/Codex 正在运行；卸载后请按 Command+Q 完全退出并重新打开"
  fi
  launchctl bootout "gui/$(id -u)/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
  remove_legacy_cli_override
  restore_codex_config || warn "Codex 配置未自动恢复，请检查状态文件和备份"
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
  log "兼容代理已卸载，Codex 已恢复原始中转站地址和 App 自带 CLI"
}

install_patch() {
  verify_app
  verify_port
  inspect_configuration
  if [ "$DRY_RUN" -eq 1 ]; then
    log "检查通过；dry-run 未修改文件或系统状态"
    exit 0
  fi
  confirm_install
  install_proxy
  configure_codex
  if ! install_launch_agent; then
    restore_codex_config || true
    die "LaunchAgent 安装失败，已尝试恢复 Codex 配置"
  fi
  if ! wait_for_health; then
    launchctl bootout "gui/$(id -u)/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
    restore_codex_config || true
    die "代理启动失败，已恢复 Codex 配置；请查看 $LOG_DIR/proxy.log"
  fi
  remove_legacy_cli_override
  remove_legacy_cli_payloads
  create_launcher
  log "版本无关的本地生图兼容代理已安装并激活"
  if is_app_running; then
    warn "当前 App 仍在运行；请按 Command+Q 完全退出后重新打开，无需重启电脑"
  else
    log "现在可以正常打开 ChatGPT/Codex；未来 App 升级无需更新 CLI 补丁"
  fi
  run_image_test
}

require_macos
require_commands
[ -f "$SOURCE_PROXY" ] || [ "$ACTION" = "uninstall" ] || die "补丁包不完整：缺少代理程序"

case "$ACTION" in
  status)
    print_status
    ;;
  uninstall)
    uninstall_patch
    ;;
  install)
    find_app
    install_patch
    ;;
esac
