# Windows Feature Roadmap

Close the Windows UI and distribution gaps while keeping the shared terminal
core aligned with upstream. Deliver tab overview, inspector, and installers
before the larger session-lifetime changes needed for undo and redo. Keep
security restrictions until a tested replacement is available.

## 1.4 release audit

The Windows 1.4 release baseline is upstream `v1.4.0` (`83fb95624`).
Merge `2d858569a` includes upstream `main` through `167acf0c4`
(November 24, 2026 UTC). Hold the Windows release tag and publication until
the common features below work on Windows and pass their acceptance checks.
The [compatibility table](README.md#ghostty-14-compatibility) summarizes
what users can rely on today.

### Clipboard, shell and terminal protocols

- [x] **Rich clipboard and paste events.** Win32 publishes Unicode text, HTML
  and PNG together with MIME-named formats such as JPEG, JSON and arbitrary
  binary data. Native Windows bitmap consumers receive a DIB. Private window
  station tests cover exact binary lengths, rejection of invalid or oversized
  format batches, and a mode 5522 HTML read authorized exactly once.
  [Native clipboard tests](test/win32/test_clipboard.ps1)
- [x] **Clipboard permissions.** The permission dialog shows the requested
  formats, text previews and image thumbnails. Native tests exercised allow,
  deny, cancel and the session grant checkbox. A lifetime regression covers
  the requesting pane closing while the dialog is open.
  [Clipboard implementation and tests](src/apprt/win32/Clipboard.zig)
- [x] **PowerShell shell integration.** Windows PowerShell 5.1 and PowerShell 7
  honor `ssh-env`, `ssh-terminfo` and `path`. Both shells passed the flag,
  argument, input, output, exit-code and PATH checks. The GUI release binary
  also kept interactive OpenSSH sessions attached to the calling console.
  [PowerShell tests](test/win32/test_shell_integration.ps1)
- [x] **Remote terminfo.** A Windows OpenSSH client connected to a disposable
  loopback OpenSSH server. A failed install left the host uncached, a retry
  installed an entry readable by `infocmp xterm-ghostty`, and the next
  connection reused the cache. The server also received the forwarded
  environment variables.
- [x] **Kitty graphics.** WGL captures verified that a child image moved with
  its parent, a client-selected frame changed color, and automatic animation
  cycled twice. The WGL context reported an NVIDIA GeForce RTX 5080,
  OpenGL 4.6.0 and NVIDIA driver 621.24. The bundled console host was
  OpenConsole 1.25.2609.30003. [Native graphics check](test/win32/test_tab_bar.ps1)
- [x] **Scrollback compression.** With a 100×30 grid, 4 MiB history limit
  and 12,000 numbered Git subjects, the compressed and uncompressed Windows
  runs retained the same rows starting at 7,803. Searching found row 11,500
  and no longer found row zero. WGL rendered sampled colors from retained
  history and the live viewport. Nine cold pages compressed from 3,575,808
  to 620,663 bytes. During two idle seconds the debug GUI working set fell
  from 130,895,872 to 127,967,232 bytes with compression, and rose from
  132,411,392 to 132,427,776 bytes without it. The working sets include WGL.
  [Repeatable Windows workload](test/win32/test_scrollback_compression.ps1)

- [x] **Primary selection.** The private Windows station test selected text
  in one window and pasted it in another through the selection binding and
  middle button. It verified that `copy-on-select=primary` preserved the
  system clipboard, `both` updated both destinations, and OSC 52 and Kitty
  honored selection locations and access policy.
  [Selection tests](src/apprt/win32/SelectionClipboard_test.zig)

### Windows, tabs and splits

- [x] **Quick-terminal environment.** PowerShell children reported
  `GHOSTTY_QUICK_TERMINAL=1` on all four edges and in a new split. The
  two split children had distinct `GHOSTTY_SURFACE_ID` values. Normal
  windows opened with the quick-terminal marker unset.
  [Native child environment checks](test/win32/test_tab_bar.ps1)

- [x] **Navigation and focus.** Window navigation wraps in both directions
  and restores the selected tab and pane. Tests verified split navigation
  with zoom preservation enabled and disabled. The live app ignored hover
  in an inactive window. A native fixture supplied foreground ownership
  and verified keyboard focus moved only for a visible pane on pointer
  movement with capture released.
  [Window lifecycle](test/win32/test_window_lifecycle.ps1),
  [live hover checks](test/win32/test_native_settings.ps1) and
  [native focus fixture](src/apprt/win32/Window.zig)
- [x] **Live split drag-and-drop.** Windows tests moved panes within a tab,
  onto an inactive tab and across windows. The original child HWND and PTY
  survived. Escape preserved geometry and focus, empty source windows
  closed, and a child could exit during capture. The tests cover all three
  `drag-handle` settings. [Native drag checks](test/win32/test_tab_bar.ps1)
- [x] **Pane context menu.** The native menu offers all four split directions
  and Close Split, including on the last pane. Windows tests opened splits
  above and to the left, canceled and confirmed a close, and preserved the
  surviving child when the menu's original pane exited.
  [Native pane-menu checks](test/win32/test_pane_menu.ps1)
- [x] **Startup and sizing.** A Windows child received an exact 66×18 grid
  with padding and an always-visible tab strip. New tabs and splits preserved
  the resized window bounds. Maximized and fullscreen startup passed.
  With `initial-window=false`, the process created no normal window and
  dispatched the registered global hotkey notification to open the quick
  terminal on each of the four edges. [Native startup checks](test/win32/test_tab_bar.ps1)
- [x] **Quick-terminal placement.** Native windows centered on each edge of
  the connected display. Geometry tests cover partial pixel and percentage
  sizes, animation endpoints, negative origins and 96, 144 and 192 DPI.
  A monitor fixture switched the same quick terminal from 96 to 144 DPI
  and back. [Placement tests](src/apprt/win32/QuickTerminal.zig) and
  [native launch checks](test/win32/test_tab_bar.ps1)
- [x] **Working-directory inheritance.** Native child processes reported the
  expected directories for windows, tabs and splits under opposing
  inheritance settings, including paths with spaces, percent signs and
  number signs reported by OSC 7. [Native lifecycle tests](test/win32/test_window_lifecycle.ps1)
- [x] **Titles.** Native editors target the pane, tab or window independently.
  Tests switch titled panes, update the OSC title under an override, clear
  the overrides, and verify the clipboard payload for the targeted pane.
  [Native title tests](src/apprt/win32/Window.zig)
- [x] **Application quit.** The native quit action checks the core's policy
  across windows. Windows tests covered a prompt, a running child in a
  background split, and a read-only surface. Canceling kept all four
  child processes alive. [Native lifecycle tests](test/win32/test_window_lifecycle.ps1)

### Native controls and feedback

- [x] **Configuration editor CLI.** Windows tests verified that
  `ghostty +edit-config` preferred `VISUAL`, fell back to `EDITOR`, and
  returned the editor's exit code. A native editor received its quoted
  arguments and the intended Unicode config path under `XDG_CONFIG_HOME`.
  Missing settings printed the config path, and a missing executable
  produced a launch error. [Native CLI tests](test/win32/test_edit_config.ps1)

- [x] **Desktop notifications.** Identical messages replace earlier ones in
  the same pane. Notifications from different panes can be clicked independently
  and clear when their pane gains focus or closes. The Windows test exercised
  stale callbacks, native timers, bounded retention and a rejected replacement
  with a test double for the Explorer notification API.
  [Native notification lifecycle test](src/apprt/win32/App.zig)

- [x] **Key and read-only indicators.** A click-through status control
  follows the selected pane. Native tests verified sequence completion and
  cancellation, table activation and removal, read-only state across reload,
  tab switching, and closing the selected pane.
  [Native indicator checks](test/win32/test_tab_bar.ps1)
- [x] **Bell behavior.** Windows honors the system sound, custom audio,
  volume, taskbar attention, title and border settings. Two panes played
  the same Unicode-named WAV independently. WGL pixel checks verified the
  border and its removal. Native tests cover disabled bells, command
  completion, background panes and clearing alerts on input or activation.
  [Audio tests](src/apprt/win32/Bell.zig) and [native dispatch tests](src/apprt/win32/App.zig)
- [x] **Pane and tab appearance.** Inactive-pane tint followed focus on
  opaque and translucent windows. The live divider changed color on reload,
  disappeared on zoom and returned on unzoom. Changing the tab title font
  changed its rendered glyphs and restoring it reproduced the original pixels.
  An overlong face name rendered the Segoe UI fallback. A missing face
  produced legible text that grew at 96, 144 and 192 DPI. Both splits reclaimed
  and restored the 32-pixel tab strip at fixed outer bounds across changes to
  `window-show-tab-bar`.
  [Windows appearance checks](test/win32/test_tab_bar.ps1) and
  [font, divider and layout checks](test/win32/test_native_settings.ps1)
- [x] **Scrollbar.** In Windows' auto-hide mode the native scrollbar appeared
  while scrolling, faded after the pointer left, and disappeared on reload to
  `scrollbar=never`. Wheel and keyboard input reached the same marked history
  rows under both policies. Reload restored the 88×27 grid. A native
  always-show fixture at 144 DPI released and restored a 21-pixel gutter.
  [Live scrolling check](test/win32/test_native_settings.ps1) and
  [Windows scrollbar fixture](src/apprt/win32/Scrollbar.zig)
- [x] **Command palette.** Windows tests clear defaults, reload without
  duplicates and invoke the 71st configured entry. Live focus commands
  search pane titles and working directories across windows and preserve
  the target identity when another pane closes.
  [Native palette tests](src/apprt/win32/Surface.zig)
- [x] **Inspector.** The native inspector renders shared terminal state,
  captures key and PTY events, and supports reopening and surface closure.
  [Native WGL and lifetime tests](src/apprt/win32/Inspector.zig)

### Changes since the release baseline

- [x] **Session theme switching.** `set_window_theme` supports `light`,
  `dark`, `system` and `config` on Windows. Native tests cover existing and
  new windows, the quick terminal, tab overview and configuration reload.
  All 914 bundled themes were checked against the upstream archive. See the
  [native window tests](src/apprt/win32/TabOverview.zig) and
  [package checks](test/win32/test_package.ps1).
- [x] **Per-tab colors.** The tab context menu opens the Windows color picker
  and clears a chosen color. Native tests followed the marked tab through
  reorder and detach, sampled its indicator in light and dark themes, and
  verified that clearing it preserves the terminal background.
  [Native tab-color tests](src/apprt/win32/Window.zig)

Live tab thumbnails, MSI/MSIX installers and Windows session undo/redo have
their own phases below. Upstream session undo/redo is macOS-specific. CLI
window-control IPC and the on-screen keyboard action are GTK-specific.

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
- [ ] Add live thumbnails to the title list. Verify previews after tab
  reorder, detach and closure, including at different monitor DPIs.

## Phase 2 Inspector

The shared Dear ImGui inspector runs in an owned Win32 window. Hidden
native-window tests rendered terminal data, captured PTY and keyboard
events, handled 144 DPI, and restored the previously current WGL context.
Closing the terminal during export and reopening the inspector are both
covered. [Inspector tests](src/apprt/win32/Inspector.zig)

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

A checked parity item should point to a passing Windows test or a recorded
end-to-end result for its acceptance checks. On each upstream sync, review
changes to shared actions, config options and the GTK/macOS handlers. Trace
each applicable behavior through its Win32 entry point and add any uncovered
work here. Record the tested commit and remaining platform limits in the
compatibility table before declaring release parity.

A phase is complete when its behavior is implemented, focused regression
tests pass, Windows debug and stripped release builds pass, and the README
and changelog describe its actual limits. Never run desktop-global input
tests on a shared working desktop. See [Testing](README.md#testing).
