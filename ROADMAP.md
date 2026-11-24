# Windows Feature Roadmap

Close the Windows UI and distribution gaps while keeping the shared terminal
core aligned with upstream. Deliver tab overview, inspector, and installers
before the larger session-lifetime changes needed for undo and redo. Keep
security restrictions until a tested replacement is available.

## 1.4 release audit

The release baseline is upstream `v1.4.0` (`83fb95624`). Development has
merged upstream `main` through `167acf0c4` (November 24, 2026 UTC). The Windows
1.4 release is held until full feature parity is implemented and verified;
sharing the core baseline alone does not satisfy the release gate. No release
tag or publication should happen while the required gaps below remain open.
See the [compatibility table](README.md#ghostty-14-compatibility).

Additional parity work identified by this audit:

- Implement full Kitty clipboard MIME representations, including images/HTML,
  paste events, and corresponding permission previews and remembered grants.
  Keep unsupported representations rejected until the full transaction can
  be preserved; a successful text copy is not a successful multi-format copy.
- Add split drag-and-drop while retaining live sessions and surface identity
  across tabs and windows. Divider resizing and whole-tab movement are already
  separate supported operations.
- Verify native `+ssh` remote terminfo installation against a live SSH server.
  Parsing and argument tests do not establish end-to-end SSH compatibility.
- Measure Windows graphics and compression behavior independently before
  making upstream conformance or benchmark claims for ConPTY/WGL.

Common native app gaps also block parity:

- Implement `goto_window` with wrapping next/previous navigation across normal
  windows; verify a selected tab/split stays associated with its owning window.
- Display active key sequences, key tables, and read-only state with the same
  core behavior and cleanup as the other apps. Test transitions, cancellation,
  configuration reload, and surface closure.
- Honor `bell-features`, including disabled bells and title/border state, and
  test focused/unfocused windows without affecting unrelated desktop windows.
- Apply `unfocused-split-opacity` and `unfocused-split-fill` to inactive panes;
  verify focus changes, zoom, transparency, and reload.
- Implement PowerShell's exported `ssh-env`, `ssh-terminfo`, and `path` shell
  features. Exercise actual feature strings and native OpenSSH, rather than
  setting test-only flags that the core never emits.

Keep platform-specific work distinct from common app behavior. Upstream
undo/redo is macOS-only, while CLI window-control IPC and the on-screen
keyboard action are GTK-specific. Windows session undo/redo, live tab
thumbnails, and installer formats remain explicit roadmap work; their absence
must not be presented as a regression introduced by the 1.4 merge.

## Phase 1 Tab overview

Status: title-list overview implemented and locally verified. Live thumbnails
remain planned.

- A native, searchable list shows the current window's tabs, including
  Unicode titles, keyboard navigation, switching, and whole-tab closing.
- `toggle_tab_overview` and the command palette open the overview.
- Close confirmation covers every split in a selected tab. Surface identities
  keep actions safe across tab reordering and child exits; background exits
  refresh the list without taking focus away from search.
- Native tests cover filtering, selection, lifecycle, and DPI behavior.
  End-to-end automation targets only test-owned window handles and checks
  session shutdown and final-window exit.
- Live thumbnails are a later increment, not part of the title-list overview.

## Phase 2 Inspector

Status: planned.

- Host the shared inspector in a Win32 window using Dear ImGui and OpenGL.
- Implement input, focus, DPI, redraw scheduling, and surface-close handling.
- Preserve render-thread ownership of WGL contexts and core lifetime guards.
- Verify terminal state inspection and event capture without leaking resources
  or exposing stale surface pointers.

## Phase 3 Installers

Status: planned.

- Add MSI and MSIX packaging alongside the portable ZIP.
- Keep the executable and resource tree together; verify configuration paths
  and launching PowerShell, cmd.exe, and WSL from an installed app.
- Test clean installation, upgrade, repair where supported, and uninstall
  without deleting user configuration.
- Establish publisher identity and signing for MSIX distribution. Release
  publishing and production signing remain maintainer operations.

## Phase 4 Undo and redo

Status: planned.

- Add a Windows undo stack for creating and closing windows, tabs, and splits.
- Retain closed sessions for the configured `undo-timeout`, with bounded
  resources and explicit expiry/shutdown cleanup.
- Preserve live processes and split layouts during that grace period.
  Recreating a dead process is not equivalent to restoring its session.
- Keep shell-command and terminal-application undo separate; this feature
  must not claim to undo commands already executed.

## Phase 5 Restricted file links

Status: security design required.

- Design confirmed local-document opening through an explicit viewer before
  considering broader path or `file:` URL support.
- Validate the final target, including shortcuts, reparse points, device and
  network paths, alternate data streams, and replacement races.
- Keep arbitrary shell dispatch blocked; extension checks alone are not a
  safe file classification policy.
- Add adversarial regression coverage before relaxing the current policy.

## Platform constraints

- `secure_input`: do not add a normal-window toggle that promises macOS-style
  keyboard protection. A separate protected input desktop would require its
  own threat model and user-experience design.
- CSI 8 t resizing is already opt-in. Test supported ConPTY versions and
  investigate upstream improvements, but do not promise delivery of requests
  ConPTY consumes before Ghostty receives them.

## Completion requirements

A phase is complete when its behavior is implemented, focused regression
tests pass, Windows debug and stripped release builds pass, and the README
and changelog describe its actual limits. Never run desktop-global input
tests on a shared working desktop. See [Testing](README.md#testing).
