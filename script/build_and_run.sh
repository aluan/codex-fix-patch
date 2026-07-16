#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/CodexImageGenProxy.xcodeproj"
SCHEME="CodexImageGenProxy"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
APP_NAME="GPTSwitch"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
PROCESS_NAME="GPTSwitch"
BUNDLE_ID="com.aluan.CodexImageGenProxy"

if [ ! -d "$PROJECT" ]; then
  /opt/homebrew/bin/xcodegen generate --spec "$ROOT_DIR/project.yml" --project "$ROOT_DIR"
fi

pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true
pkill -x CodexImageGenProxy >/dev/null 2>&1 || true

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    /usr/bin/lldb -- "$APP_BUNDLE/Contents/MacOS/$PROCESS_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$PROCESS_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
