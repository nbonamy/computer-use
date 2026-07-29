#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CALLER_DIR="$PWD"

usage() {
  echo "Usage: $0 --app-name <name> --bundle-identifier <id> --icon <path> [--output <path>]" >&2
  exit 2
}

APP_NAME=""
BUNDLE_IDENTIFIER=""
ICON_PATH=""
OUTPUT_DIR="$PACKAGE_DIR/dist"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name) APP_NAME="${2:-}"; shift 2 ;;
    --bundle-identifier) BUNDLE_IDENTIFIER="${2:-}"; shift 2 ;;
    --icon) ICON_PATH="${2:-}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$APP_NAME" && -n "$BUNDLE_IDENTIFIER" && -n "$ICON_PATH" ]] || usage
if [[ "$ICON_PATH" != /* ]]; then
  ICON_PATH="$CALLER_DIR/$ICON_PATH"
fi
if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$CALLER_DIR/$OUTPUT_DIR"
fi
[[ -f "$ICON_PATH" ]] || { echo "Icon not found: $ICON_PATH" >&2; exit 2; }

EXECUTABLE_NAME="computer-use-pilot"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$PACKAGE_DIR"
swift build

if [[ -e "$APP_DIR" ]]; then
  BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/computer-use-previous-app.XXXXXX")"
  mv "$APP_DIR" "$BACKUP_DIR/$(basename "$APP_DIR")"
  echo "Preserved previous bundle at $BACKUP_DIR/$(basename "$APP_DIR")" >&2
fi
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$PACKAGE_DIR/.build/debug/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
cp "$PACKAGE_DIR/Sources/ComputerUsePilotCore/Resources/computer-use-cursor.svg" "$RESOURCES_DIR/computer-use-cursor.svg"
sed \
  -e "s|__APP_NAME__|$APP_NAME|g" \
  -e "s|__BUNDLE_IDENTIFIER__|$BUNDLE_IDENTIFIER|g" \
  "$PACKAGE_DIR/Bundle/Info.plist" > "$CONTENTS_DIR/Info.plist"
cp "$ICON_PATH" "$RESOURCES_DIR/icon.icns"
chmod 755 "$MACOS_DIR/$EXECUTABLE_NAME"
codesign --force --sign - --identifier "$BUNDLE_IDENTIFIER" "$APP_DIR" >/dev/null

echo "$APP_DIR"
