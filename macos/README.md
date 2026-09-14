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

## Computer Use v2

Every request has an `id`, `command`, and optional `arguments`. Every response repeats the `id` and has either `ok: true` with `result`, or `ok: false` with a stable structured error.

`status` reports the release version as `2.0.0`. This is diagnostic product
metadata, not a negotiated protocol version: a consumer ships the exact helper
binary and adapter it was built against as one release unit.

The public command surface is:

- `status`, `request_accessibility`, `request_screen_capture`
- `list_apps`, `find_apps`, `launch_app`, `focus_app`
- `screenshot`
- `get_app_state`, `click`, `dismiss`, `type_text`, `set_value`, `scroll`
- `press_key`, `drag`, `perform_secondary_action`, `paste`, `select_text`

The helper is stateful. Consumers must reuse one process for an active Computer
Use session and terminate it when the session ends. Stable element identifiers,
hierarchy-diff baselines, post-action settling, and the cursor overlay all live
for that process lifetime.

Clicks use macOS Accessibility actions by default. `mouse_button` accepts
`left`, `right`, or `middle` (and `l`, `r`, or `m`). Consumers may pass
`physical: true` to synthesize a real foreground mouse click for a visible
control, such as an Electron/web control that accepts `AXPress` without acting.
Right and middle clicks are necessarily physical. Physical clicks and drags
require the target app to remain frontmost and unobstructed.

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

`get_app_state` returns a coherent observation containing compact Accessibility
text and, by default, a target-window screenshot. A missing Screen Recording
permission does not fail Accessibility inspection: `screenshot` is `null` and
`screenshotError` explains why. Pass `includeScreenshot: false` to skip capture.

The first observation for an app, scope, subtree root, and traversal-budget
combination is a full hierarchy. Later observations are diffs by default:

- `+` means added.
- `~` means changed or moved.
- `-` means removed.

Each result includes `stateKind`, `stateRevision`, and, for a diff,
`baseRevision`. Pass `disableDiff: true` to force a full hierarchy and establish
a new baseline. Pass `includeContextSnapshot: true` when a consumer needs the
current full text for transient model-context compaction; do not expose or
persist that duplicate field unnecessarily.

The leading number on each hierarchy line is a session-stable
`element_index`, not a traversal ordinal. Indexed actions resolve through the
latest in-process element registry and fail with `stale_element` when an element
is gone or belongs to another app. The helper never silently redirects a stale
index to a different control.

After a successful mutation, the next observation for that app waits at least
one second and then waits for the app's Accessibility busy state to clear, up
to five seconds total. This lets callers inspect settled UI without duplicating
fixed delays in every adapter.

`type_text`, `press_key`, and `paste` require an explicit app or pid. Keyboard
events are posted directly to that process rather than the global event stream,
so the app need not be frontmost. The helper stops if the target process exits
during delivery. Consumers should use `set_value` for
ordinary settable controls and reserve synthetic typing for controls that need
keyboard semantics.

`press_key` accepts a key or `+`-separated chord using X keysym-style names,
for example `Return`, `Control_L+a`, or `Super_L+v`. Common aliases such as
`Ctrl`, `Shift`, `Alt`, `Option`, `Command`, and `Cmd` are accepted.

`drag` accepts `from_x`, `from_y`, `to_x`, and `to_y` in macOS global logical
screen coordinates. `perform_secondary_action` accepts an action advertised on
the element in the latest state. `paste` accepts `text`, `md`, or `html`, uses
the system paste command, and restores the previous pasteboard only if nothing
else changed it during the operation. `select_text` selects an exact match in
an indexed editable element, with optional `prefix`, `suffix`, and
`selection_type` (`text`, `cursor_before`, or `cursor_after`).

## Consumer contract

Consumers must:

1. Gate inspection and mutation behind an explicit user-granted Accessibility status.
2. Enforce their own action approval policy and model-facing size limits.
3. Bundle the helper under their own product name, icon, bundle ID, and signing identity.
4. Never parse diagnostics from stdout; it is protocol-only.
5. Keep the helper process alive for the complete Computer Use session.
