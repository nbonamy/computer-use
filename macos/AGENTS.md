# macOS Computer Use Pilot

This project owns the reusable native Swift helper for macOS Computer Use.

## Scope

- The helper is a standalone macOS Accessibility pilot, not an MCP server.
- Apps call it over newline-delimited JSON on stdin/stdout; stdout is reserved for JSON responses.
- The helper is product-neutral. Each consuming desktop app owns its model tools, approval policy, packaging, bundle identifier, icon, signing, and permissions UI.
- Do not add app-specific defaults, tool names, filesystem paths, or branding here.

## Accessibility contracts

- `status` and `request_accessibility` work without Accessibility permission.
- `find_apps` and `launch_app` work without Accessibility permission.
- UI inspection and action commands require Accessibility trust.
- Keep traversal and text budgets optional. Product-facing caps belong to the consumer.

## Build and test

```bash
swift build
swift test
scripts/build-app.sh --app-name "Example Computer Use" --bundle-identifier com.example.computer-use --icon /absolute/path/icon.icns
```

The generated bundle is for local permission testing only. Consumers should bundle and sign their own copy.
