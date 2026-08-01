#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PACKAGE_DIR/dist"
VERSION=""

usage() {
  echo "Usage: $0 --version <version> [--output <directory>]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) shift; VERSION="$1"; shift ;;
    --output) shift; OUTPUT_DIR="$1"; shift ;;
    *) usage ;;
  esac
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || usage
if [[ "$OUTPUT_DIR" != /* ]]; then OUTPUT_DIR="$PWD/$OUTPUT_DIR"; fi

cd "$PACKAGE_DIR"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/computer-use-pilot"
RESOURCE_PATH="$PACKAGE_DIR/Sources/ComputerUsePilotCore/Resources/computer-use-cursor.svg"
STAGE_PARENT="$(mktemp -d /tmp/computer-use-artifact.XXXXXX)"
STAGE_DIR="$STAGE_PARENT/computer-use-pilot-macos-arm64-$VERSION"
ARCHIVE_PATH="$OUTPUT_DIR/computer-use-pilot-macos-arm64-$VERSION.tar.gz"
trap 'rm -rf "$STAGE_PARENT"' EXIT

[[ -x "$BIN_PATH" ]] || { echo "Release binary not found: $BIN_PATH" >&2; exit 1; }
[[ -f "$RESOURCE_PATH" ]] || { echo "Cursor resource not found: $RESOURCE_PATH" >&2; exit 1; }
mkdir -p "$STAGE_DIR/bin" "$STAGE_DIR/Resources" "$STAGE_DIR/scripts" "$STAGE_DIR/Bundle" "$OUTPUT_DIR"
cp "$BIN_PATH" "$STAGE_DIR/bin/computer-use-pilot"
cp "$RESOURCE_PATH" "$STAGE_DIR/Resources/computer-use-cursor.svg"
cp "$SCRIPT_DIR/package-app.sh" "$STAGE_DIR/scripts/package-app.sh"
cp "$PACKAGE_DIR/Bundle/Info.plist" "$STAGE_DIR/Bundle/Info.plist"
chmod 755 "$STAGE_DIR/bin/computer-use-pilot" "$STAGE_DIR/scripts/package-app.sh"
printf '%s\n' "$VERSION" > "$STAGE_DIR/VERSION"
tar -C "$STAGE_PARENT" -czf "$ARCHIVE_PATH" "$(basename "$STAGE_DIR")"
shasum -a 256 "$ARCHIVE_PATH" | tee "$OUTPUT_DIR/SHA256SUMS"
echo "$ARCHIVE_PATH"
