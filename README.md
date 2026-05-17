# wmark

`wmark` is a macOS window target picker for safely telling Codex which local window or Chrome tab to operate.

The project name means "window mark". It marks a user-selected window with a short target id so Codex can resolve that target later without guessing, moving windows, or relying on macOS Spaces.

See [docs/plan.md](docs/plan.md) for the initial product plan.
See [docs/privacy-and-safety.md](docs/privacy-and-safety.md) for the local data and safety model.

## Current experiment

This repository currently contains a minimal Swift CLI for validating the macOS APIs needed by the MVP.

```sh
swift build
.build/debug/wmark scan
.build/debug/wmark chrome-front
.build/debug/wmark thumbnail <windowId>
.build/debug/wmark mark-frontmost
.build/debug/wmark queue
.build/debug/wmark resolve <targetId>
```

`mark-frontmost` writes short-lived local target records under `~/.codex/window-targets/` and copies `target: WTG-xxxx` to the pasteboard.
`resolve` revalidates a saved target against the current window state and stops unless one current window matches the saved `windowId + pid + app`.
All target records use the same top-level window schema. Chrome title and URL are optional values inside `context`; the MVP targets macOS windows rather than individual Chrome tabs.

Window thumbnails and target queues may contain sensitive local window data. Keep them outside Git.

## App experiment

The repository also contains an early SwiftUI app experiment.

```sh
swift run wmark-app
```

The app can:

- scan visible macOS windows
- show a local preview thumbnail when hovering a row
- click a row to copy `target: WTG-xxxx`
- use `Cmd+Shift+M` to enter selection mode
- highlight the window under the cursor
- click the highlighted window to register and copy a target

The app does not move windows, switch Spaces, foreground unrelated windows, or operate a target by itself.

## Public safety model

`wmark` is intended to be public and user-facing. The safety boundary is:

- target records are short-lived local candidates, not truth
- target resolution must re-check the current window state
- stale, missing, used, or ambiguous targets must stop
- thumbnails and queue data stay under `~/.codex/window-targets/`
- raw screenshots, URL history, browser profiles, cookies, and credentials must not be committed
