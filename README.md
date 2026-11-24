<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="Logo" width="128">
  <br>Ghostty for Windows
</h1>
  <p align="center">
    Native Windows port of the Ghostty terminal emulator.
    <br />
    <a href="#status">Status</a>
    ·
    <a href="#building">Building</a>
    ·
    <a href="#keyboard-shortcuts">Shortcuts</a>
    ·
    <a href="#configuration">Configuration</a>
    ·
    <a href="https://ghostty.org/docs">Upstream Docs</a>
  </p>
</p>

## About

This is a fork of [Ghostty](https://github.com/ghostty-org/ghostty) that adds **native Windows support** via a Win32 application runtime. It runs as a standalone `.exe` — no WSL, no Cygwin, no compatibility layers.

The goal is to track the upstream main branch while maintaining a native Windows port that leverages Ghostty's cross-platform core (terminal emulation, renderer, font system).

> **Upstream Ghostty** supports Linux (GTK) and macOS natively. This fork adds a `win32` application runtime alongside those existing backends. See the [upstream repository](https://github.com/ghostty-org/ghostty) for the original project.

## Status

Native Windows runtime using the shared upstream terminal core. Platform-specific
behavior is implemented separately; handling an action is not a guarantee of
macOS/GTK feature parity.

### Ghostty 1.4 compatibility

The Windows release target remains upstream 1.4.0 (`83fb95624`, October 27,
2026). The development branch includes 456 subsequent upstream commits through
`167acf0c4` in the upstream `1.4.1-dev` series.
The planned `win-v1.4.0` release remains on hold pending the Windows parity
checks below. [Upstream 1.4.0 release notes](https://ghostty.org/docs/install/release-notes/1-4-0)

| Area | Windows status |
|------|----------------|
| Terminal parsing, reset, checksums, snapshots, and security fixes | Integrated from 1.4.0; focused core and Windows tests cover the shared behavior. ConPTY can consume some sequences before they reach Ghostty. |
| Kitty graphics animation and relative placements | With the bundled ConPTY host, WGL capture tests verified frame selection, automatic animation, and a child image following its parent placement. |
| Scrollback compression and memory reclamation | Native Windows tests verified pruning, search and rendering. With a 4 MiB history limit and 12,000 Git subjects, nine cold pages compressed from 3.41 MiB to 0.59 MiB. |
| `ghostty +ssh` | Windows OpenSSH installed a usable `xterm-ghostty` entry on a live loopback server, retried a failed install, and reused the cached result. |
| Kitty clipboard (OSC 5522) | Reads and writes multiple MIME representations together, including JSON, JPEG and custom binary formats. Plain text, HTML and PNG also interoperate with native Windows text, rich-text and bitmap consumers. Mode 5522 lists clipboard targets and authorizes one follow-up read. Permission dialogs preview the content and can remember a client’s grant. |
| Splits | Create, resize, zoom or equalize panes. Drag a pane by its grip to another pane, tab or window while its child keeps running. `split-preserve-zoom=navigation` moves zoom to the destination pane. |
| Window navigation and state indicators | `goto_window:next` and `goto_window:previous` restore each window’s selected pane. `focus-follows-mouse` switches panes within the foreground window. A click-through status control shows active key sequences, key tables and read-only state. |
| Window sizing and scrolling | Normal windows honor the configured grid, maximize, and fullscreen at launch. Opening another tab or split preserves the window bounds. `scrollbar=system` follows Windows accessibility settings. `scrollbar=never` releases the gutter and keeps keyboard and wheel scrolling available. |
| Bell and inactive-pane appearance | Inactive panes honor the configured fill and opacity on opaque and transparent windows. `bell-features` controls the system alert, custom audio and volume, taskbar attention, title and pane border. |
| PowerShell shell features | Prompt marks, directory/title reports, cursor features, `ssh-env`, `ssh-terminfo`, and `path` work in Windows PowerShell 5.1 and PowerShell 7. Interactive OpenSSH keeps the calling console. |
| Window theme | The `set_window_theme` action accepts `light`, `dark`, `system`, or `config`. Use `config` to restore the configured `window-theme`. |
| Tab overview and colors | The native overview lists searchable titles. Right-click a tab to set or clear its color. The color follows the tab when reordered or moved to a new window. Live thumbnails remain planned. |
| Inspector and session undo/redo | The native WGL inspector shows shared terminal state, input and PTY events. Windows session undo/redo remains on the roadmap. |
| Distribution | Portable x64 ZIP; MSI/MSIX installers are unavailable. |

The Windows audit also covers clipboard ownership and malformed text,
surface destruction during close confirmation, canceled graphics commands,
PowerShell prompt injection, and hidden-window visibility. See the
[roadmap](ROADMAP.md) for the remaining product work and
[testing instructions](#testing) for the checks behind these claims.

### Features

**Terminal**
- Shared upstream terminal emulation with OpenGL 4.3+ rendering (WGL)
- FreeType + HarfBuzz fonts with DirectWrite system font discovery
- ConPTY shell spawning (cmd.exe, PowerShell, WSL) using the bundled Microsoft
  console host to keep terminal protocol handling consistent across Windows versions
- Win32 Input Mode (mode 9001) for full Unicode through ConPTY
- IME support for CJK input (Japanese, Chinese, Korean) with the
  composition (preedit) rendered inline at the cursor and the candidate
  window anchored to it
- AltGr layouts (German, Polish, …) encode correctly
- Per-monitor DPI awareness, window resize with grid reflow
- Bundled upstream color themes

**Windows & Tabs**
- Multiple windows, tabbed interface with custom GDI tab bar
- Standalone theme-colored tab strip with centered titles and hover close buttons on the right
- Change `window-title-font-family`, `window-show-tab-bar`, and `split-divider-color` on reload
- Tab drag-and-drop reorder, inline rename (double-click), right-click context menu
- Close tab modes: current, all others, all to the right
- Searchable native tab overview with keyboard switching and whole-tab closing

**Split Panes**
- Split right/down/left/up, navigate between panes
- Mouse drag to resize dividers, double-click to equalize
- Toggle split zoom, equalize all splits
- Independent split tree per tab

**Security**
- Paste protection: unsafe/multi-line pastes prompt before reaching the
  shell (`clipboard-paste-protection`)
- OSC 52 and Kitty clipboard authorization prompts show the requested formats,
  a bounded text preview and a thumbnail for images. A Kitty client can ask
  for a remembered grant for reads or writes. Unsupported formats leave the
  current clipboard intact.

**Extras**
- Command palette with filterable actions, keybinding hints, and
  user-defined entries (`command-palette-entry`)
- Right-click a terminal pane to copy, paste, select all, split in any of
  four directions, close that pane, or reset the terminal. **Close Split**
  uses the same confirmation policy as the keyboard action.
- Taskbar progress for OSC 9;4 progress reports (`ITaskbarList3`)
- Global hotkeys for any `global:`-flagged keybind (not just the quick
  terminal)
- `window-theme` honored for the title bar (dark / light / system / auto)
- Background blur (acrylic-style) behind translucent windows
  (`background-blur` with `background-opacity < 1`)
- Resize overlay showing columns × rows while resizing (`resize-overlay`)
- Hovered-URL preview bubble (browser-style, bottom-left)
- Search bar match counter ("3/17")
- Command-finished notifications (`notify-on-command-finish*`): bell
  and/or a desktop notification with duration and exit code
- Desktop notifications (OSC 9 and OSC 777) raise the originating pane when
  clicked. Repeated messages replace earlier ones in that pane. Focusing or
  closing a pane clears its notifications.
- X1/X2 (back/forward) mouse buttons delivered to the terminal
- `window-decoration = none` (borderless) and `window-position-x/y`
- Renderer occlusion: hidden tabs, zoomed-out splits, and minimized
  windows stop rendering (saves GPU/CPU/battery)
- Quick terminal (slide-in/out from screen edge with global hotkey)
- Find-in-terminal search bar
- URL detection with Ctrl+click to open in browser
- Background opacity, fullscreen, window decorations toggle
- Font size zoom with inheritance to new tabs/splits
- Config hot-reload, scrollbar
- DWM dark/light chrome and Win11 22H2+ caption color matching the
  configured background
- Shell integration for PowerShell (prompt marking, CWD, title)
- Drag a file from Explorer onto the terminal to paste its path
- Visual bell (taskbar flash) when BEL fires on an unfocused window
- Taskbar flash when a command exits non-zero in an unfocused window
- Confirm-close dialogs for running commands, including tab-strip X and
  middle-click closes; a tab close checks every split and confirms once
- Auto-update check against GitHub releases (rate-limited to once per
  hour); clicking the "Update available" balloon opens the releases
  page in your browser
- Horizontal scroll wheels / trackpad gestures (`WM_MOUSEHWHEEL`)

### Platform-Specific Notes

- Planned Windows work and completion criteria are tracked in the [roadmap](ROADMAP.md).
- Inspector (debug overlay) — acknowledged but no Win32 UI yet
- `undo`/`redo` — not implemented on Windows; a custom bounded undo stack is planned
- `secure_input` — macOS EnableSecureEventInput only
- Tab overview uses a searchable title list; live thumbnails are not implemented
- Portable release ZIP is supported; MSI/MSIX installers are not implemented
- Terminal-supplied HTTP(S)/mailto links open directly; custom protocols require
  confirmation. Untrusted paths and `file:` URLs are blocked until Windows has
  safe canonical-file classification. Ghostty-generated text/HTML exports still open.
- Program-requested window resizing (CSI 8 t) is disabled by default; enable
  `vt-window-resize-allowed` to allow it for a normal single-tab, unsplit window.
  Zero dimensions are preserved and oversized requests are clamped to the monitor.
  ConPTY versions can consume subsequent or zero-valued resize requests before
  forwarding them, so Windows cannot guarantee that every CSI 8 t reaches Ghostty.

## Building

Requires [Zig](https://ziglang.org/download/) 0.17.1.

### Native build on Windows (recommended)

```powershell
.\dist\windows\build.ps1 -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu
```

The executable is at `zig-out/bin/ghostty.exe`. Building with the native
Windows Zig toolchain is the most reliable path and is also the
authoritative compile check.

The `-Dtarget=x86_64-windows-gnu` flag matters even on Windows: with the
GNU ABI Zig provides its own bundled libc (MinGW), whereas omitting the
target selects the MSVC ABI, which requires an installed Visual Studio /
Windows SDK and otherwise fails every C dependency with
`error: failed to find libc installation: WindowsSdkNotFound`.

To replace a `ghostty.exe` that is currently running, rename the old file
aside first — Windows write-locks a running executable against overwrite
but still allows it to be renamed.

### Cross-compile from Linux/WSL2

Use `bash dist/windows/build.sh -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu`
from Linux with the GNU ABI target
(`x86_64-windows-gnu` — the plain `x86_64-windows` target selects the MSVC
ABI, which cannot cross-compile from Linux because it lacks the MSVC
headers).

The wrapper excludes unreadable Windows `PATH` entries from Zig's compiler
probes while leaving the calling shell's `PATH` unchanged, so `powershell.exe`,
`cmd.exe`, and other Windows test tools remain available. It prefers the pinned
Zig version under `~/.local/zig-versions`; set `ZIG` to select another compiler.
Cross-compiling is not the same as running the native tests: use
`test-build` to compile them, then run from a local Windows directory with their
fixtures as described under [Testing](#testing).

### Keep the desktop development build current

For local development from WSL, use this command after changing the code:

```bash
bash dist/windows/build-desktop.sh
```

It builds the current working tree in release mode and, only after a successful
build, refreshes **Ghostty Dev** on the Windows desktop. Use that shortcut for
development instead of manually copied executables. Set `ZIG=/path/to/zig` if
Zig 0.17.1 is not on your `PATH` or under `~/.local/zig-versions`. Pass `debug`,
`safe`, or `small` as the optional argument to select another optimization mode.

The executable, console host, themes, and shell integration are installed together under
`%LOCALAPPDATA%\ghostty-dev\builds`. Each distinct build gets its own directory,
including resource-only changes. Previous builds stay available so existing
terminal windows keep working; launch the shortcut again to use the new build.
This follows local builds, without pulling remote changes or downloading releases.

To publish an existing `zig-out` build from Windows PowerShell instead:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File dist/windows/install-dev.ps1
```

### Build cache

The desktop and packaging scripts automatically prune stale cache entries
before building. For other builds and tests, use `bash dist/windows/build.sh`
on Linux/WSL or `.\dist\windows\build.ps1` on Windows, followed by the usual
`zig build` arguments (for example, `test-build -Dtest-filter=Screen`).

Pruning retains entries accessed or modified within 30 days, the newest producer
of each artifact name, and all cache entries referenced by those roots. It
understands both object and build-configuration manifest outputs, so retained
metadata cannot refer to deleted artifacts. Downloaded packages, compiler IR
caches, temporary files, and installed development builds stay available.

The wrapper holds `.zig-cache.lock` through pruning and the complete build.
Other wrappers wait for that lock. A wrapped `run` holds it until the launched
app exits; use the desktop shortcut for sessions that stay open during later
builds. Pruning is deferred when another Zig process
is running or metadata cannot be interpreted. Use the wrappers for concurrent
development; direct Zig invocations do not participate in this lock. Custom
cache directories selected with `--cache-dir` or `ZIG_LOCAL_CACHE_DIR` are
measured but left untouched because they may be shared with other projects.

Regular `zig build` commands also run a native size check, including cached
builds, and warn above 20 GiB. This is a warning threshold rather than a hard cap:
recent and referenced artifacts are retained even above the threshold. Prefer
a consistent Zig version and optimization mode and use `-Dtest-filter` for
focused tests to limit compiled variants.

### Release build

```bash
bash dist/windows/build.sh -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=fast
```

To debug a release build with stderr visible, add `-Dwindows-console=true`
— it links against `/SUBSYSTEM:CONSOLE` instead of the default Windows
GUI subsystem so the process gets a console attached.

### Portable packaging

From WSL with Zig 0.17.1 and Windows interop available:

```bash
bash dist/windows/package.sh
```

To build a local release candidate from the working tree, pass an explicit
Semantic Versioning prerelease such as `bash dist/windows/package.sh --candidate 1.4.0-rc.1`.
The script appends the short Git commit to the build metadata. The executable
and ZIP use `1.4.0-rc.1+<commit>`, and Explorer reports `1.4.0.0`.

Once the parity gate is satisfied, check out the clean annotated release tag and run
`bash dist/windows/package.sh --release`. Release packaging checks the exact tag,
executable version, and numeric/string PE versions. Both development and release
packaging reject incomplete resources and validate the portable layout.

The ZIP is written to `dist/windows/ghostty-windows-x64-<version>.zip`.
Extract it anywhere, keeping `ghostty.exe`, `conpty.dll`, and `OpenConsole.exe`
together beside the bundled `share/` tree. The pinned Microsoft ConPTY backend
is downloaded automatically when building the Windows app; its MIT license is
included under `share/licenses/conpty/`.
`share/terminfo/ghostty.terminfo` is the resource-directory sentinel; themes
and automatic shell integration depend on that layout. Packaging does not
install files under `%LOCALAPPDATA%`; that directory is used for configuration.
Publishing a release uses an annotated `win-vX.Y.Z` tag; see
[the release workflow](AGENTS.md#windows-resources-and-packaging).

## Keyboard Shortcuts

All keybindings are configurable via the `keybind` config option. These are the defaults:

### General

| Action | Shortcut |
|--------|----------|
| New window | `Ctrl+Shift+N` |
| Close surface (tab/pane) | `Ctrl+Shift+W` |
| Close window | `Alt+F4` |
| Toggle fullscreen | `Ctrl+Enter` |
| Command palette | `Ctrl+Shift+P` |
| Open config file | `Ctrl+,` |
| Reload config | `Ctrl+Shift+,` |
| Quit | `Ctrl+Shift+Q` |

### Tabs

| Action | Shortcut |
|--------|----------|
| New tab | `Ctrl+Shift+T` |
| Next tab | `Ctrl+Page Down` |
| Previous tab | `Ctrl+Page Up` |
| Go to tab 1–8 | `Ctrl+1` – `Ctrl+8` |
| Go to last tab | `Ctrl+9` |
| Move tab left | `Ctrl+Shift+Page Up` |
| Move tab right | `Ctrl+Shift+Page Down` |
| Drag reorder | Mouse drag on tab |
| Close tab and its splits | Middle-click tab or click its X button |
| Rename tab | Double-click tab |
| Tab context menu | Right-click tab |

Open **Tab Overview** from the command palette, or bind the
`toggle_tab_overview` action to a key. Type to filter titles, use Up/Down to
select, Enter to switch, and Escape to dismiss. Tab moves focus between the
search field, list, and buttons. **Close tab** closes every split in the
selected tab, with one confirmation if any split requires it. The overview
shows tabs in the current normal window, not the quick terminal.

### Split Panes

| Action | Shortcut |
|--------|----------|
| Split right | `Ctrl+Shift+O` |
| Split down | `Ctrl+Shift+E` |
| Focus next pane | `Ctrl+Shift+]` |
| Focus previous pane | `Ctrl+Shift+[` |
| Equalize splits | Configurable (`equalize_splits`) |
| Toggle split zoom | Configurable (`toggle_split_zoom`) |
| Resize split | Mouse drag on divider |
| Equalize split | Double-click divider |

### Text & Clipboard

| Action | Shortcut |
|--------|----------|
| Copy | `Ctrl+Shift+C` |
| Paste | `Ctrl+Shift+V` |
| Select all | `Ctrl+Shift+A` |
| Find | `Ctrl+Shift+F` |
| Find next | `Enter` (in search bar) |
| Find previous | `Shift+Enter` (in search bar) |
| Close search | `Escape` |

Set `copy-on-select=primary` to keep the most recent selection available to
every pane and window in this Ghostty process. Middle-click and
`paste_from_selection` paste that selection. The default is
`copy-on-select=none`. Use `copy-on-select=both` to also copy to Windows.
OSC 52's selection and primary locations and Kitty's `loc=primary` use the
same private selection and honor clipboard permissions.

Kitty OSC 5522 exposes MIME-named Windows clipboard formats. Ghostty records
the byte length of each custom format it writes, preserving empty payloads and
trailing zero bytes. For data from other applications, Ghostty uses the length
of an OLE stream when available. A native memory block with no length metadata
exposes its full allocation, which can include alignment padding.

A transaction can contain up to 128 representations and 256 MiB of data.
Windows keeps registered format names for the lifetime of its window station.
Ghostty creates up to 64 new MIME names per process and stops creating names
when the station reaches 4,096 registered formats. Existing names remain usable.
An invalid or over-limit write leaves the previous clipboard contents intact.

### Font Size

| Action | Shortcut |
|--------|----------|
| Increase font size | `Ctrl+=` |
| Decrease font size | `Ctrl+-` |
| Reset font size | `Ctrl+0` |

### Mouse

| Action | Gesture |
|--------|---------|
| Vertical scroll | Mouse wheel |
| Horizontal scroll | Trackpad swipe / horizontal wheel |
| Drag-select | Left-click drag |
| Open URL | `Ctrl+Click`; use `Ctrl+Shift+Click` when a TUI captures the mouse |
| Middle-click paste | Middle button (configurable via `middle-click-action`) |
| Drop file | Drag a file from Explorer onto the terminal — its path is pasted |

### Quick Terminal

The quick terminal requires a keybinding in your config:

```
keybind = global:ctrl+grave_accent=toggle_quick_terminal
```

The `global:` prefix makes the shortcut work when another application has focus.
Shells in the quick terminal and its splits receive `GHOSTTY_QUICK_TERMINAL=1`.

## Configuration

The preferred config file is `%LOCALAPPDATA%\ghostty\config.ghostty`.
If `XDG_CONFIG_HOME` is set, use `%XDG_CONFIG_HOME%\ghostty\config.ghostty`
instead. The legacy filename `config` is also supported. When both files
exist, Ghostty loads `config` first, then `config.ghostty`.

Run `ghostty +edit-config` to open the preferred config file. Set
`VISUAL` or `EDITOR` to the editor command, quoting an executable path
that contains spaces. Ghostty uses `VISUAL` first, passes any editor options
before the config path, and returns the editor's exit code. If neither
variable has a value, it prints the config path.

Example:

```
# Font
font-family = JetBrains Mono
font-size = 14

# Colors
background = #1e1e2e
foreground = #cdd6f4

# Shell
command = powershell.exe

# Behavior
quit-after-last-window-closed = true

# Quick terminal (global hotkey)
keybind = global:ctrl+grave_accent=toggle_quick_terminal
```

See the [upstream documentation](https://ghostty.org/docs/config) for the full list of config options. Most settings work on Windows — the exceptions are platform-specific options (GTK, macOS).

### Windows update checks

Automatic checks run at startup, at most once per hour. Set `auto-update = off`
to disable those checks. Unset, `check`, and `download` all enable notification-only
checks on Windows; updates are not downloaded or installed automatically.
The `check_for_updates` action explicitly checks even when automatic checks are
off or the hourly limit has not elapsed. `auto-update-channel` is macOS-only.

### PowerShell integration

Windows PowerShell 5.1 (`powershell.exe`) and PowerShell 7 (`pwsh.exe`) load
the bundled integration automatically when shell integration is enabled.
No PowerShell profile edit or fixed installation path is required. Keep the
portable `share/` tree beside `ghostty.exe`; use `shell-integration = none`
to disable integration. See the [implementation notes](src/shell-integration/README.md#powershell)
for prompt markers, working-directory reporting, title, and cursor behavior.

### WSL shell integration and mouse recovery

The Windows app exports its terminal metadata and translated resource path
through `WSLENV`. To enable integration in WSL zsh, add this to `~/.zshrc`:

```zsh
if [[ ${TERM_PROGRAM-} == ghostty && -n ${GHOSTTY_RESOURCES_DIR-} ]]; then
  source "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
fi
```

The zsh prompt disables mouse tracking left behind by crashed programs or SSH
disconnects. Running applications can still enable mouse support normally.
For immediate recovery, open the command palette with `Ctrl+Shift+P` and select
**Reset Mouse Reporting**, or bind the `reset_mouse_reporting` action. This
preserves terminal contents and history.

### Windows transparency

`background-opacity` changes the terminal background, not text, cursors, images,
or explicit cell backgrounds. Enable `background-opacity-cells` separately to
make cell backgrounds translucent. `toggle_background_opacity` forces an opaque
background until toggled back. Reload still updates the configured value while
forced-opaque mode remains set.

Transparency uses DirectComposition with hardware `WGL_NV_DX_interop2` support.
The GPU presentation pass writes a stable shared texture, then copies it into
the DXGI backbuffer; terminal frames are never copied through CPU memory.
Unsupported presentation drivers emit an explicit transparency-unavailable
warning and switch to an opaque WGL terminal.
The tab strip follows the terminal's effective opacity and shares its blurred
backdrop. Labels and button glyphs stay opaque. Its cached GDI pixel buffers are
updated only when the strip changes, independently of terminal frames.
Dividers and native title editors remain opaque on a separate GDI surface.
The native title bar retains its existing caption color and Windows controls.

`background-blur` requests untinted blur-behind when configured opacity is below
1, leaving the theme's background color and `background-opacity` to supply the
tint. This uses the checked, undocumented Windows accent API. If that request
fails, Ghostty warns and tries Desktop Acrylic, whose additional tint is
OS-controlled and can look brighter.
`false` or `0` disables blur. `true` or any positive integer enables it; values
such as `20` and `50` do not select different blur strengths on Windows.
Windows controls the blur radius, and accessibility or power policy can
suppress the effect. Unavailable blur APIs produce a warning rather than a
software substitute.

## Architecture

The Windows port adds a `win32` application runtime (`src/apprt/win32/`) alongside the existing GTK (Linux) and AppKit (macOS) runtimes. It reuses Ghostty's cross-platform core:

- **Terminal emulation**: Shared VT parser, screen, scrollback (`src/terminal/`)
- **Rendering**: OpenGL 4.3+ with WGL context management and hardware DirectComposition presentation (`src/renderer/`)
- **Fonts**: FreeType rasterization + HarfBuzz shaping + DirectWrite discovery (`src/font/`)
- **PTY**: Windows ConPTY via `CreatePseudoConsole` (`src/pty.zig`)
- **I/O**: libxev with IOCP backend (`src/termio/`)

### Key files

```
src/apprt/win32/
  App.zig             — Win32 message loop, window classes, action dispatch
  Window.zig          — Top-level container HWND, tab bar, splits, tab lifecycle
  Surface.zig         — WS_CHILD HWND, WGL context, input, clipboard, search, command palette
  QuickTerminal.zig   — Quick terminal popup with slide animation
  UntrustedUrl.zig    — Terminal-supplied URL validation and confirmation policy
  win32.zig           — Win32 API type definitions and extern declarations

src/renderer/opengl/
  WGLDevice.zig       — Windows adapter for the shared renderer device API

src/shell-integration/powershell/
  ghostty-shell-integration.ps1  — PowerShell prompt marking, CWD, title
```

## Testing

The November 24, 2026 upstream audit used Zig 0.17.1. On Linux, the
libghostty-vt suite passed 7,259 tests and skipped 74. Both debug and
stripped fast Windows application builds passed. The Windows
integration checks passed for program-requested resize, tab overview,
terminal reply handling, mouse reporting and visibility. The tab-strip suite
passed 69 checks across 31 test runs. Shell integration,
portable payload validation and development installation passed under
Windows PowerShell 5.1 and PowerShell 7.

### Zig unit tests

From a local Windows checkout:

```powershell
.\dist\windows\build.ps1 test -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu
# Prefer a filter for focused changes:
.\dist\windows\build.ps1 test -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Dtest-filter="program resize"
```

From WSL, compile without executing the Windows test runner:

```bash
bash dist/windows/build.sh test-build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Demit-test-exe=true
```

Add `-Dtest-filter="program resize"` or `-Dtest-filter="tab overview"` to compile
a focused test executable.
The installed test binary is `zig-out/bin/ghostty-test.exe`.

To run that binary from a WSL checkout, open PowerShell at the repository root
and stage it with the reference fixtures in a fresh local Windows directory.
Build the application first to populate the matching console runtime files:

```powershell
$repo = (Get-Location).Path
$testDir = Join-Path $env:TEMP ("ghostty-unit-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testDir | Out-Null
Copy-Item (Join-Path $repo 'zig-out\bin\ghostty-test.exe') (Join-Path $testDir 'ghostty-unit.exe')
foreach ($runtime in @('conpty.dll', 'OpenConsole.exe')) {
    Copy-Item (Join-Path $repo "zig-out\bin\$runtime") (Join-Path $testDir $runtime)
}
foreach ($fixture in @('src\terminal\snapshot\testdata', 'src\font\sprite\testdata', 'src\font\testdata')) {
    $destination = Join-Path $testDir $fixture
    New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
    Copy-Item (Join-Path $repo $fixture) $destination -Recurse
}
Push-Location $testDir
try {
    & .\ghostty-unit.exe
    if ($LASTEXITCODE -ne 0) { throw "Tests failed: $LASTEXITCODE" }
} finally {
    Pop-Location
}
```

The local working directory matters: file-loading security tests reject UNC
paths. Snapshot and font reference tests also need the fixtures above. Do not
weaken security checks or assume a test is broken because its launch directory
or reference files are wrong. The staging directory is left in `%TEMP%` for
inspection.

### Tests without desktop input

After building the app, the WSL harness can run these focused GUI tests:

```bash
bash test/win32/ghostty_test.sh program_window_resize
bash test/win32/ghostty_test.sh tab_overview
bash test/win32/ghostty_test.sh reply_feedback
bash test/win32/ghostty_test.sh mouse_reporting
bash test/win32/ghostty_test.sh visibility
```

The resize test uses a file handshake. The overview test sends messages only
to window handles validated against its own process; it covers Unicode
filtering, switching, close confirmation, split-tab closing, and child exits.
The reply-feedback test uses a WSL Python 3 child to echo terminal responses,
simulating an SSH disconnect without sleeping the desktop or using a server.
It covers device attributes, keyboard flags, glyph support/coverage/clearing,
and clipboard status replies; clipboard access is denied for the test.
The mouse-reporting test uses WSL Python 3 and zsh to check reporting before a
disconnect, prompt cleanup, and re-enabling reports for the next application.
The visibility test uses controlled WSL children and test-owned HWNDs to verify
mode 2033 across hiding, hidden resizes, tab changes, split zoom,
minimize/restore, and quick-terminal animation.
These tests use no desktop-global keyboard/mouse injection. The harness stages the
app under Windows `%TEMP%`. The `resize` and `window_properties` cases also
avoid global input.

The standalone tab-strip regression test runs directly under PowerShell 7:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File test/win32/test_tab_bar.ps1 `
  -ExePath "$PWD/zig-out/bin/ghostty.exe" `
  -ResourcesPath "$PWD/zig-out/share" `
  -OutputDirectory "$env:TEMP/ghostty-tab-bar-proof" -Case all
```

It validates every target HWND against its own app process before sending
messages, without global input injection or foreground requests. Dark opaque,
dark translucent, and light fixtures exercise tab creation, keyboard and mouse
selection, independent PTY input, right-side closing, and inline title editing.
Use `-Case native-settings` to check scrollbar reload, wheel and keyboard
scrolling, tab font rendering, divider color, and split focus. On a shared
desktop the focus check uses whichever window Windows already put in front.
JSON results, app logs, and native window captures are saved in the output
directory. Blur is disabled in these fixtures; this is not a compositing test.
The native composition regression uses PowerShell 7 and an idle interactive
desktop. It sends input messages only to validated test-owned HWNDs, without
global keyboard/mouse injection or foreground requests. Its non-activating
backdrop and app windows form an owned capture scene; screenshots are actual
desktop-composited pixels, not PrintWindow output.

```powershell
pwsh.exe -NoProfile -File test/win32/test_composition.ps1 `
  -ExePath "$PWD/zig-out/bin/ghostty.exe" `
  -ResourcesPath "$PWD/zig-out/share/ghostty" `
  -OutputDirectory "$env:TEMP/ghostty-composition-proof" -Case all
```

Use `-Case opacity`, `blur`, `chrome`, `creation`, or `lifecycle` for focused checks.
The harness `toggle_opacity` case invokes the same native opacity regression.
The fixtures disable resize overlays and update notifications, preserve the
personal configuration, and reject obscured or focus-changing captures.
The `chrome` case checks translucent tab backgrounds, opaque labels and title
editing, dark/light reloads, and live tab-strip blur. Creation traces cover the
incoming frame's actual reveal, with terminal-edge, interior, stable tab-chrome,
and independent-session input assertions.
PNG/JSON evidence and app logs are saved in the output directory.

The clipboard regression tests run against a private Windows window station.
Build a focused test executable and stage it together with the ConPTY runtime
files in a local Windows directory as described above. From the repository
root, run the harness with the path to that staged executable.

```bash
bash dist/windows/build.sh test-build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Demit-test-exe=true '-Dtest-filter=Windows clipboard'
```

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File test/win32/test_clipboard.ps1 -TestExe (Join-Path $testDir 'ghostty-unit.exe')
```

The harness checks native text, HTML and bitmap formats, MIME-named formats
with exact binary lengths, Kitty paste events, and the permission dialog’s
three responses. It also checks one-time and persistent read grants and
cross-window selection pastes with the system clipboard held separately.
The normal test suite skips the private-station case on the working desktop.

The PowerShell integration regression test captures VT output in memory and
needs neither a GUI nor the app binary. Run from the repository root in Windows:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File test/win32/test_shell_integration.ps1
pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File test/win32/test_shell_integration.ps1
```

Windows CI runs it under both Windows PowerShell 5.1 and PowerShell 7.

### Global-input tests: isolated desktop only

The full GUI suite and the tab, split, and IME scripts inject desktop-global
input. They refuse to run unless `GHOSTTY_TEST_ISOLATED_DESKTOP=1` is explicitly
set for a dedicated, isolated desktop. Never enable this on the desktop where
you are working: Windows focus requests can fail or race. From WSL, the flag
must be set in its environment and listed in `WSLENV` so Windows children also
receive it.

Only on that isolated desktop:

```bash
bash test/win32/ghostty_test.sh all
```

The standalone tab and split scripts have the same guard. Run from Windows
PowerShell with an app executable on a local Windows path:

```powershell
powershell.exe -ExecutionPolicy Bypass -File test/win32/test_tabs.ps1 -ExePath path\to\ghostty.exe
powershell.exe -ExecutionPolicy Bypass -File test/win32/test_splits.ps1 -ExePath path\to\ghostty.exe
```

## Syncing with Upstream

This fork tracks `ghostty-org/ghostty` main branch.

The latest merged upstream commit is `167acf0c4` (November 24, 2026 UTC).
The 456 commits since `v1.4.0` include DEC column and index operations,
scrollback and snapshot fixes, faster text rendering, SSH terminfo setup
updates, and independent versioning of libghostty-vt. The app build and
Windows CI use Zig 0.17.1. See the [libghostty-vt packaging guide](PACKAGING-LIBGHOSTTY.md)
for the library’s separate version and build instructions.

Configure the `upstream` remote once if it is missing:

```bash
git remote add upstream https://github.com/ghostty-org/ghostty.git
```

Start from an up-to-date, clean `main`, and merge on a review branch:

```bash
git fetch upstream
git switch -c sync/upstream-YYYY-MM-DD main
git merge upstream/main
```

For a versioned release, merge its exact upstream tag (as for `v1.4.0`) to keep
the release baseline separate from subsequent development on upstream main.

Optionally enable reusable conflict resolutions in your checkout with
`git config rerere.enabled true`. Always review reused resolutions too.

Do not resolve shared files by blindly taking upstream. Windows-specific
adaptations live outside `src/apprt/win32/`, `dist/windows/`, and `test/win32/`
as well. Preserve and re-audit these contracts:

- `.win32` switch arms, Windows config defaults, font discovery, and ConPTY
  handle types in shared code.
- WGL device selection and render-thread GPU resource ownership, context
  recovery, and bounded shutdown in `src/renderer/` and `src/Surface.zig`.
- Synchronous ConPTY resize outside the renderer-state lock in
  `src/termio/Termio.zig`, plus PowerShell command construction and integration.
- Windows-targeted C translations, system libraries, resources, GNU ABI,
  and SEH unwind tables in stripped releases in `src/build/` and `build.zig`.
- Deferred URL opening outside core locks, untrusted-target checks, and
  shutdown cleanup of queued requests.
- Fork CI/toolchain pins, shared-desktop input guards, and packaging layout.
  Do not reactivate upstream publishing workflows as a merge side effect.

Before merging, run targeted native tests, both debug and stripped release
builds, the no-input integration checks, and formatting checks. Use an isolated
desktop for any global-input suite; compilation alone does not establish UI
feature parity.

Files most likely to conflict on upstream merges:
- `src/Surface.zig`, `src/config/Config.zig`, `src/font/discovery.zig`,
  `src/font/DeferredFace.zig`, `src/font/backend.zig`
- Switch-arm files: `src/apprt/runtime.zig`, `src/apprt.zig`,
  `src/datastruct/split_tree.zig`, `src/input/Binding.zig`,
  `src/font/face.zig`, `src/terminal/mouse.zig`
- Renderer and build files: `src/renderer/OpenGL.zig`, `src/renderer/Thread.zig`,
  `src/renderer/generic.zig`, `src/termio/Termio.zig`, `src/termio/Exec.zig`,
  `src/termio/shell_integration.zig`, `src/build/GhosttyExe.zig`,
  `src/build/SharedDeps.zig`, and `.github/workflows/windows-ci.yml`

## License

Same as upstream Ghostty — see [LICENSE](LICENSE).
