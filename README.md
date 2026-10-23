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

### Features

**Terminal**
- Shared upstream terminal emulation with OpenGL 4.3+ rendering (WGL)
- FreeType + HarfBuzz fonts with DirectWrite system font discovery
- ConPTY shell spawning (cmd.exe, PowerShell, WSL)
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
- OSC 52 clipboard read/write authorization prompts
  (`clipboard-read` / `clipboard-write = ask`)

**Extras**
- Command palette with filterable actions, keybinding hints, and
  user-defined entries (`command-palette-entry`)
- Right-click context menu on the terminal (Copy / Paste / Select All /
  Split / Reset)
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
- Desktop notifications are click-to-focus (raise the originating tab)
- X1/X2 (back/forward) mouse buttons delivered to the terminal
- `window-decoration = none` (borderless) and `window-position-x/y`
- Renderer occlusion: hidden tabs, zoomed-out splits, and minimized
  windows stop rendering (saves GPU/CPU/battery)
- Quick terminal (slide-in/out from screen edge with global hotkey)
- Find-in-terminal search bar
- URL detection with Ctrl+click to open in browser
- Desktop notifications (OSC 9, OSC 777)
- Background opacity, fullscreen, window decorations toggle
- Font size zoom with inheritance to new tabs/splits
- Config hot-reload, scrollbar
- DWM dark/light chrome and Win11 22H2+ caption color matching the
  configured background
- Shell integration for PowerShell (prompt marking, CWD, title)
- Drag a file from Explorer onto the terminal to paste its path
- Visual bell (taskbar flash) when BEL fires on an unfocused window
- Taskbar flash when a command exits non-zero in an unfocused window
- Confirm-close dialog when a programmatic close hits a tab with a
  running command
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

Requires [Zig](https://ziglang.org/download/) 0.17.0.

### Native build on Windows (recommended)

```bash
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu
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

The same command works from Linux with the GNU ABI target
(`x86_64-windows-gnu` — the plain `x86_64-windows` target selects the MSVC
ABI, which cannot cross-compile from Linux because it lacks the MSVC
headers).

If a WSL build fails with `AccessDenied` while probing an unreadable Windows
`PATH` entry, use a Linux-only `PATH` for that build command:

```bash
ghostty_build_path="$(printf '%s' "$PATH" | tr ':' '\n' | awk '!/^\/mnt\/[A-Za-z]\//' | paste -sd: -)"
PATH="$ghostty_build_path" zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu
```

This leaves the calling shell's `PATH` unchanged so `powershell.exe`, `cmd.exe`,
and other Windows test tools remain available. Zig 0.17.0 must be on the Linux
build path. Cross-compiling is not the same as running the native tests: use
`test-build` to compile them, then run from a local Windows directory with their
fixtures as described under [Testing](#testing).

### Release build

```bash
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=fast
```

To debug a release build with stderr visible, add `-Dwindows-console=true`
— it links against `/SUBSYSTEM:CONSOLE` instead of the default Windows
GUI subsystem so the process gets a console attached.

### Portable packaging

From WSL with Zig 0.17.0 and Windows interop available:

```bash
bash dist/windows/package.sh
```

The ZIP is written to `dist/windows/ghostty-windows-x64-<version>.zip`.
Extract it anywhere, keeping `ghostty.exe` beside the bundled `share/` tree.
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
| Open URL | `Ctrl+Click` on a detected URL |
| Middle-click paste | Middle button (configurable via `middle-click-action`) |
| Drop file | Drag a file from Explorer onto the terminal — its path is pasted |

### Quick Terminal

The quick terminal requires a keybinding in your config:

```
keybind = global:ctrl+grave_accent=toggle_quick_terminal
```

The `global:` prefix makes it work system-wide, even when Ghostty isn't focused.

## Configuration

The preferred config file is `%LOCALAPPDATA%\ghostty\config.ghostty`.
If `XDG_CONFIG_HOME` is set, use `%XDG_CONFIG_HOME%\ghostty\config.ghostty`
instead. The legacy filename `config` is also supported. When both files
exist, Ghostty loads `config` first, then `config.ghostty`.

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

## Architecture

The Windows port adds a `win32` application runtime (`src/apprt/win32/`) alongside the existing GTK (Linux) and AppKit (macOS) runtimes. It reuses Ghostty's cross-platform core:

- **Terminal emulation**: Shared VT parser, screen, scrollback (`src/terminal/`)
- **Rendering**: OpenGL 4.3+ with WGL context management (`src/renderer/`)
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

### Zig unit tests

From a local Windows checkout:

```powershell
zig build test -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu
# Prefer a filter for focused changes:
zig build test -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Dtest-filter="program resize"
```

From WSL, compile without executing the Windows test runner:

```bash
zig build test-build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Demit-test-exe=true
```

Add `-Dtest-filter="program resize"` or `-Dtest-filter="tab overview"` to compile
a focused test executable.
The installed test binary is `zig-out/bin/ghostty-test.exe`.

To run that binary from a WSL checkout, open PowerShell at the repository root
and stage it with the reference fixtures in a fresh local Windows directory:

```powershell
$repo = (Get-Location).Path
$testDir = Join-Path $env:TEMP ("ghostty-unit-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testDir | Out-Null
Copy-Item (Join-Path $repo 'zig-out\bin\ghostty-test.exe') (Join-Path $testDir 'ghostty-unit.exe')
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
```

The resize test uses a file handshake. The overview test sends messages only
to window handles validated against its own process; it covers Unicode
filtering, switching, close confirmation, split-tab closing, and child exits.
Neither uses desktop-global keyboard/mouse injection. The harness stages the
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
JSON results, app logs, and native window captures are saved in the output
directory. Blur is disabled in these fixtures; this is not a compositing test.

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

Last integrated upstream: `f54340ad7` (2026-10-21). This includes the shared
terminal fixes, Kitty graphics/render-state and snapshot updates, checksum
reporting controls, paste protection, and libghostty-vt API updates. Windows
retains WGL/ConPTY; upstream's GTK EGL/DMABUF presentation path is Linux-specific.
The toolchain and Windows CI now use Zig 0.17.0 (`-Doptimize=fast` for releases).

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
