#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
    --app-name) shift; APP_NAME="$1"; shift  ;;
    --bundle-identifier) shift; BUNDLE_IDENTIFIER="$1"; shift ;;
    --icon) shift; ICON_PATH="$1"; shift ;;
    --output) shift; OUTPUT_DIR="$1"; shift ;;
    *) usage ;;
  esac
done

[[ -n "$APP_NAME" && -n "$BUNDLE_IDENTIFIER" && -n "$ICON_PATH" ]] || usage
if [[ "$ICON_PATH" != /* ]]; then ICON_PATH="$CALLER_DIR/$ICON_PATH"; fi
if [[ "$OUTPUT_DIR" != /* ]]; then OUTPUT_DIR="$CALLER_DIR/$OUTPUT_DIR"; fi
[[ -f "$ICON_PATH" ]] || { echo "Icon not found: $ICON_PATH" >&2; exit 2; }

cd "$PACKAGE_DIR"
swift build
"$SCRIPT_DIR/package-app.sh" \
  --app-name "$APP_NAME" \
  --bundle-identifier "$BUNDLE_IDENTIFIER" \
  --icon "$ICON_PATH" \
  --binary "$PACKAGE_DIR/.build/debug/computer-use-pilot" \
  --resource-dir "$PACKAGE_DIR/Sources/ComputerUsePilotCore/Resources" \
  --output "$OUTPUT_DIR"
