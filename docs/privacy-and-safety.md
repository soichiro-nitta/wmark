# Privacy and Safety

`wmark` is designed for explicit local window targeting.

It does not move windows, switch macOS Spaces, foreground unrelated windows, or operate a target by itself.

## Local Data

`wmark` stores short-lived target records and thumbnails under:

```text
~/.codex/window-targets/
```

These files may contain sensitive local window metadata or screenshots. They must stay local and must not be committed to Git.

## Target Resolution

A saved target is only a candidate. Consumers must re-check the current window state before operating.

The MVP identity is:

```text
windowId + pid + app
```

If the target is missing, stale, used, or ambiguous, consumers must stop.

## App-Specific Context

All target records use the same top-level window schema. App-specific details, such as Chrome tab title or URL, belong in optional `context`.

The MVP does not require Chrome tab identity to resolve a target.

## Permissions

Window thumbnails may require macOS Screen Recording permission. Future selection and shortcut features may require Accessibility permission.

Permission requests should be explained in product UI before users are sent to System Settings.
