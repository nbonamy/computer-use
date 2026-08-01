# Computer Use

Reusable native helpers for Computer Use.

The macOS pilot CI workflow tests every change and builds release artifacts.
Pushing a vX.Y.Z tag publishes a versioned arm64 archive containing the
product-neutral binary, resources, and app wrapper script for consumers.

The first implementation is a product-neutral macOS Accessibility pilot. It
communicates over newline-delimited JSON, leaving model tools, approvals,
packaging, signing, and product branding to the application that embeds it.

See [the macOS guide](macos/README.md) for requirements, development, and the
protocol.

See [function-calling integrations](docs/function-calling.md) for the
recommended agentic-app integration.

## License

Licensed under the [Apache License 2.0](LICENSE).
