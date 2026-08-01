#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CALLER_DIR="$PWD"

usage() {
  echo "Usage: $0 --app-name <name> --bundle-identifier <id> --icon <path> --binary <path> --resource-dir <path> [--output <path>]" >&2
  exit 2
}

APP_NAME=""
BUNDLE_IDENTIFIER=""
ICON_PATH=""
BINARY_PATH=""
RESOURCE_DIR=""
OUTPUT_DIR="$CALLER_DIR/dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name) shift; APP_NAME="$1"; shift ;;
    --bundle-identifier) shift; BUNDLE_IDENTIFIER="$1"; shift ;;
    --icon) shift; ICON_PATH="$1"; shift ;;
    --binary) shift; BINARY_PATH="$1"; shift ;;
    --resource-dir) shift; RESOURCE_DIR="$1"; shift ;;
    --output) shift; OUTPUT_DIR="$1"; shift ;;
    *) usage ;;
  esac
done

[[ -n "$APP_NAME" && -n "$BUNDLE_IDENTIFIER" && -n "$ICON_PATH" && -n "$BINARY_PATH" && -n "$RESOURCE_DIR" ]] || usage

resolve_path() {
  local value="$1"
  if [[ "$value" != /* ]]; then value="$CALLER_DIR/$value"; fi
  printf '%s\n' "$value"
}

ICON_PATH="$(resolve_path "$ICON_PATH")"
BINARY_PATH="$(resolve_path "$BINARY_PATH")"
RESOURCE_DIR="$(resolve_path "$RESOURCE_DIR")"
OUTPUT_DIR="$(resolve_path "$OUTPUT_DIR")"

[[ -f "$ICON_PATH" ]] || { echo "Icon not found: $ICON_PATH" >&2; exit 2; }
[[ -x "$BINARY_PATH" ]] || { echo "Computer Use binary not executable: $BINARY_PATH" >&2; exit 2; }
[[ -f "$RESOURCE_DIR/computer-use-cursor.svg" ]] || { echo "Computer Use cursor resource not found." >&2; exit 2; }
[[ -f "$PACKAGE_DIR/Bundle/Info.plist" ]] || { echo "Bundle template not found." >&2; exit 2; }

APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

if [[ -e "$APP_DIR" ]]; then
  BACKUP_DIR="$(mktemp -d /tmp/computer-use-previous-app.XXXXXX)"
  mv "$APP_DIR" "$BACKUP_DIR/$(basename "$APP_DIR")"
  echo "Preserved previous bundle at $BACKUP_DIR/$(basename "$APP_DIR")" >&2
fi

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BINARY_PATH" "$MACOS_DIR/computer-use-pilot"
cp "$RESOURCE_DIR/computer-use-cursor.svg" "$RESOURCES_DIR/computer-use-cursor.svg"
sed -e "s|__APP_NAME__|$APP_NAME|g" -e "s|__BUNDLE_IDENTIFIER__|$BUNDLE_IDENTIFIER|g" "$PACKAGE_DIR/Bundle/Info.plist" > "$CONTENTS_DIR/Info.plist"
cp "$ICON_PATH" "$RESOURCES_DIR/icon.icns"
chmod 755 "$MACOS_DIR/computer-use-pilot"
codesign --force --sign - --identifier "$BUNDLE_IDENTIFIER" "$APP_DIR" >/dev/null
echo "$APP_DIR"
