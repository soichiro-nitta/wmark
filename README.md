# wmark

`wmark` is a macOS window target picker for safely telling Codex which local window or Chrome tab to operate.

The project name means "window mark". It marks a user-selected window with a short target id so Codex can resolve that target later without guessing, moving windows, or relying on macOS Spaces.

See [docs/plan.md](docs/plan.md) for the initial product plan.

## Current experiment

This repository currently contains a minimal Swift CLI for validating the macOS APIs needed by the MVP.

```sh
swift build
.build/debug/wmark scan
.build/debug/wmark chrome-front
.build/debug/wmark thumbnail <windowId>
.build/debug/wmark mark-frontmost
```

`mark-frontmost` writes short-lived local target records under `~/.codex/window-targets/` and copies `target: WTG-xxxx` to the pasteboard.

Window thumbnails and target queues may contain sensitive local window data. Keep them outside Git.
