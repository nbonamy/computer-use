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

`status` reports the release version as `3.0.0`. This is diagnostic product
metadata, not a negotiated protocol version: a consumer ships the exact helper
binary and adapter it was built against as one release unit.

The public command surface is:

- `status`, `request_accessibility`, `request_screen_capture`
- `list_apps`, `list_windows`, `find_apps`, `launch_app`, `focus_app`
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

Physical clicks move the real pointer smoothly to the target and leave it there
after clicking. Movement posts native mouse-move events, suppresses the virtual
cursor halo and stops before clicking if the target app loses focus.

The helper shows a click-through blue cursor halo so users can see Computer Use
activity. The halo itself does not move the hardware pointer; an opted-in
physical click does. The halo lives for the helper process session. Consumers
own the inactivity timeout and end the session by terminating the helper.
Screenshots temporarily hide an existing halo during capture and restore it
afterward without triggering a new halo.

`status`, `request_accessibility`, `request_screen_capture`,
`find_apps`, and `launch_app` do not require Accessibility access. Inspection
and mutation commands do. Screenshot capture instead requires macOS Screen
Recording permission. Window screenshots additionally require Accessibility
access to resolve the exact selected window; full-screen capture does not.

### Window targeting

`list_windows` accepts an app selector and returns `app`, `success`, and
`windows`: entries with `window_id`, `title`, `frame`, `is_key`, and
`is_minimized`. IDs are positive integers local to this helper session, distinct
from element indexes and native screenshot window IDs. Listing does not change
the selected window. `list_apps` is unchanged.

`get_app_state`, window `screenshot`, `focus_app`, and all actions require
an explicit positive integer `window_id` from `list_windows`. Missing or malformed
IDs return `invalid_request` before any action occurs. There is no implicit
current-window or remembered-window fallback. After creating a new window, call
`list_windows` and explicitly select its ID.
A closed or foreign window returns `window_not_found`; it never falls back.

Application observations now traverse only the selected window, return its
`window_id`, and use that same window for the header, metadata, and screenshot.
Subtrees must belong to it. Diff baselines are separate per window. Capture
matches the window's title and bounds in ScreenCaptureKit; an ambiguous or missing
match returns a screenshot error rather than capturing a different window.
Read-only menu-bar inspection remains app-wide, needs no `window_id`, and omits
window screenshots. Menu actions still require `window_id` and select that
window before invoking the app-wide menu, since menu commands can affect it.
Discovery, app launch, permission checks, and full-screen screenshots do not
require a window ID.

AX element actions remain usable in the background. Cross-window element or
coordinate targets return `window_mismatch`. Keyboard input selects and verifies
the requested window's keyboard focus before delivery, returning
`window_focus_failed` if selection fails. Background keyboard targeting does not
raise the window. Physical
clicks, drags, and unindexed scrolling additionally activate the app.

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

The first observation for an app, window, scope, subtree root, and traversal-budget
combination is a full hierarchy. Later observations are diffs by default:

- `+` means added.
- `~` means changed or moved.
- `Removed IDs:` lists removed element IDs as compact ranges.

If a diff would be larger than the full hierarchy, the helper returns a new
full baseline instead. Identical titles and descriptions are emitted only once.

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

After a successful mutation, the next observation waits for bounded stability
of the selected window's AX descendants, including busy states (five seconds
by default). `waitForText` additionally requires matching AX text;
`timeoutMs` may be set from 1 to 15000. The returned `settling` metadata reports
timeouts. Stable AX state is evidence, not proof that the application completed
the intended operation; consumers must inspect the result.
Web-document `AXLoaded` and `AXLoadingProgress` participate in readiness, not
just `AXElementBusy`. Text conditions require a sustained match but do not
require unrelated text (such as countdowns) to stop changing. The wait budget
is checked during sampling; an individual macOS AX call can still overrun it.

Compact text preserves short standalone facts (including prices and stock
status). It omits empty noninteractive groups and text exactly repeated by a
rendered ancestor, rather than guessing that short text is a control label.

Pass the app selector and selected `window_id` to `type_text`, `press_key`, and
`paste`. Keyboard events are posted directly to that process after verifying
the selected window's keyboard focus, without raising the window;
keyboard typing stops if that window loses focus or the process exits during delivery.
`type_text` accepts an `element_index` or semantic selector to target an
editable control. With a target, `replace: true` selects its
existing text before typing; `submit: true` sends Return afterward. Targeted
keyboard typing stops if the editable control loses focus. Unknown command arguments
are rejected rather than silently ignored.
When the targeted editable is not already focused, the helper focuses it in the
background: the app is told it became active and receives a click on the
control, routed to its own event queue. The user's frontmost app, window order,
and pointer stay unchanged, and new text is appended after existing content
unless `replace` is set. Minimized windows are refused, and focus that does not
move returns an error before input. Untargeted text requires the selected window
to already hold the app's keyboard focus.

`type_text` types text as keystrokes, which background apps accept silently;
they usually reject a synthetic paste with a system beep. Tabs and newlines send
Tab and Return. The selected window and targeted control are verified before
typing and before an optional Return. Results report `charactersTyped`.
An empty string inserts nothing; `replace` and `submit` still apply.
Consumers can use `set_value` for ordinary settable controls.

`press_key` accepts a key or `+`-separated chord using X keysym-style names,
for example `Return`, `Control_L+a`, or `Super_L+v`. Common aliases such as
`Ctrl`, `Shift`, `Alt`, `Option`, `Command`, and `Cmd` are accepted.

`drag` accepts `from_x`, `from_y`, `to_x`, and `to_y` in macOS global logical
screen coordinates. `perform_secondary_action` accepts an action advertised on
the element in the latest state. `paste` inserts formatted `md` or `html` (or plain
`text`) with the system paste command, which apps usually accept only while in
the foreground. It snapshots every pasteboard item and format first, returning
`clipboard_snapshot_failed` before replacing anything it cannot read, and
restores the snapshot only if nothing else changed the pasteboard meanwhile; a
failed restore returns `clipboard_restore_failed`. `select_text` selects an exact match in
an indexed editable element, with optional `prefix`, `suffix`, and
`selection_type` (`text`, `cursor_before`, or `cursor_after`).

## Consumer contract

Consumers must:

1. Gate inspection and mutation behind an explicit user-granted Accessibility status.
2. Enforce their own action approval policy and model-facing size limits.
3. Bundle the helper under their own product name, icon, bundle ID, and signing identity.
4. Never parse diagnostics from stdout; it is protocol-only.
5. Keep the helper process alive for the complete Computer Use session.
