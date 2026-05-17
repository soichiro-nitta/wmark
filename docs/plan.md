# wmark Product Plan

## Purpose

`wmark` is a macOS tool for safely telling Codex "operate this window".

The goal is not to move windows or infer the user's current macOS Space. The goal is to let the user explicitly select a window or Chrome tab, save a short-lived local target record, and pass a short id to Codex.

## Background

A previous approach tried to detect the macOS Space that contains the current Codex thread and move newly-created windows back to that Space. That approach was too fragile because macOS does not provide a stable public API for safely moving arbitrary windows between Spaces, and moving existing windows risks affecting unrelated user work.

`wmark` changes the model. Instead of moving windows, the user marks the target. Codex then resolves the mark against the current local window state and stops if the target is stale or ambiguous.

## User Idea

- The app's main window shows a scan of currently open windows.
- The list includes app name, window title, Chrome tab title and URL when available, a scan id, and capture time.
- Hovering a list item shows a visual preview of that window.
- Clicking a list item copies a short target id such as `target: WTG-A7F3`.
- A global shortcut opens a window selection mode.
- In selection mode, the window under the cursor is highlighted with a visible frame.
- Clicking the highlighted window marks it and copies its target id.
- Codex can be told "operate WTG-A7F3" and use the local target record to identify the window.
- Used targets should become clean, either removed or marked as used.

## Assistant Additions

`wmark` should act as a temporary target registry rather than a window automation tool.

For the MVP, the marked unit is a macOS window. Chrome tab title and URL can be stored as optional context when available, but the target record should keep one uniform top-level window schema across all applications.

It should store target records in a local, Git-ignored location, for example:

```text
~/.codex/window-targets/queue.json
~/.codex/window-targets/thumbs/
```

A target record should include enough evidence to validate the target later:

```json
{
  "id": "WTG-A7F3",
  "kind": "window",
  "app": "Google Chrome",
  "pid": 12345,
  "windowId": 987654,
  "windowTitle": "GitHub",
  "bounds": { "x": 100, "y": 80, "width": 1400, "height": 900 },
  "thumbnailPath": "~/.codex/window-targets/thumbs/WTG-A7F3.png",
  "capturedAt": "2026-05-17T15:12:38+09:00",
  "status": "pending",
  "context": {
    "chromeTabTitle": "Pull Request #88",
    "chromeURL": "https://github.com/example/repo/pull/88"
  }
}
```

## Resolution Rules

Codex-side resolution should be conservative.

- `windowId + pid + app` is a strong match.
- App-specific context can help users recognize a target, but the MVP does not require it for identity.
- If the marked window no longer exists, treat the target as `stale`.
- If multiple candidates match, do not operate and ask the user to clarify.
- If no candidate matches, do not operate.
- Do not move existing windows between Spaces.
- Do not foreground a different Space just because a target might be there.

## MVP

1. Create the repository and product plan.
2. Research window metadata collection with `CGWindowListCopyWindowInfo`.
3. Research Chrome front tab metadata through AppleScript or another local API.
4. Research window thumbnails with `CGWindowListCreateImage` or a modern equivalent.
5. Implement a small CLI or Swift experiment that scans visible windows and writes a target queue.
6. Implement marking the frontmost window and copying `target: WTG-xxxx`.
7. Implement conservative target resolution from the queue.
8. Implement an early SwiftUI app with scan list, hover preview, click-to-copy, and selection mode.

## Later Features

- Main GUI with scanned window list.
- Hover preview thumbnails.
- Click-to-copy target id.
- Global shortcut for selection mode.
- Cursor hover window highlight.
- Click-to-mark selection mode.
- `pending`, `used`, and `stale` lifecycle.
- Automatic cleanup for old targets and thumbnails.

## Safety

- Window thumbnails may contain sensitive data, so they must remain local and outside Git.
- Old thumbnails and targets should expire quickly.
- The app should never store credentials, cookies, or raw browser profiles.
- The app should not move, activate, or reuse unrelated existing windows automatically.
