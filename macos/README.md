# Computer Use macOS Pilot

Reusable macOS Accessibility helper for desktop products. It receives newline-delimited JSON on stdin and writes exactly one JSON response per input line to stdout.

Consumer release builds should download a versioned archive from the GitHub
release, verify its SHA-256 checksum, and run its bundled package-app.sh with
the consumer's app name, bundle identifier, icon, and output directory.
Consumers still own final signing and notarization.

This project is deliberately product-neutral: it does not expose MCP tools or own agent approval policy. A consumer owns the model-facing tool schema, starts this executable, packages the resulting app bundle, and signs that bundle with its own identity.

## Development

```bash
swift build
swift test
```

Build a locally signed helper bundle for permission testing:

```bash
scripts/build-app.sh \
  --app-name "Example Computer Use" \
  --bundle-identifier com.example.computer-use \
  --icon /absolute/path/icon.icns
```

Optional `--output /absolute/path` selects the output directory. The command prints the generated `.app` path.

## Protocol

Every request has an `id`, `command`, and optional `arguments`. Every response repeats the `id` and has either `ok: true` with `result`, or `ok: false` with a stable structured error.

The public command surface is:

- `status`, `request_accessibility`, `request_screen_capture`
- `list_apps`, `find_apps`, `launch_app`, `focus_app`
- `screenshot`
- `get_app_state`, `click`, `dismiss`, `type_text`, `set_value`, `scroll`

Clicks use macOS Accessibility actions by default. Consumers may pass
`physical: true` to synthesize a real foreground mouse click for a visible
control, such as an Electron/web control that accepts `AXPress` without acting.
Physical clicks require the target app to remain frontmost and unobstructed.

The helper shows a click-through blue cursor halo so users can see Computer Use
activity. The halo itself does not move the hardware pointer; an opted-in
physical click does. The halo lives for the helper process session. Consumers
own the inactivity timeout and end the session by terminating the helper.
Screenshots temporarily hide an existing halo during capture and restore it
afterward without triggering a new halo.

`status`, `request_accessibility`, `request_screen_capture`, `screenshot`,
`find_apps`, and `launch_app` do not require Accessibility access. Inspection
and mutation commands do. Screenshot capture instead requires macOS Screen
Recording permission.

`screenshot` accepts `scope: "window" | "screen"`. Window capture is the
default and accepts the standard optional app selector (`app`, `pid`, or the
frontmost application when omitted). Screen capture defaults to the main
display and accepts an optional positive `displayId`. Both modes return PNG
base64 plus pixel dimensions, scale factor, logical bounds, and target
metadata.

`get_app_state` returns compact, line-numbered Accessibility text. Element indexes remain valid only while the target app's UI tree has not changed structurally.

`type_text` requires an explicit app or pid and stops if that process does not
own both foreground and Accessibility focus. Consumers should use `set_value`
for ordinary settable controls and reserve synthetic typing for controls that
need keyboard semantics.

## Consumer contract

Consumers must:

1. Gate inspection and mutation behind an explicit user-granted Accessibility status.
2. Enforce their own action approval policy and model-facing size limits.
3. Bundle the helper under their own product name, icon, bundle ID, and signing identity.
4. Never parse diagnostics from stdout; it is protocol-only.
