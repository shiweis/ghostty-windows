# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## Commands

- **Build:** `zig build`
  - If you're on macOS and don't need to build the macOS app, use
    `-Demit-macos-app=false` to skip building the app bundle and speed up
    compilation.
- **Test (Zig):** `zig build test`
  - Prefer to run targeted tests with `-Dtest-filter` because the full
    test suite is slow to run.
- **Test filter (Zig)**: `zig build test -Dtest-filter=<test name>`
- **Formatting (Zig)**: `zig fmt .`
- **Formatting (Swift)**: `swiftlint lint --strict --fix`
- **Formatting (other)**: `prettier -w .`

## libghostty-vt

- Build: `zig build -Demit-lib-vt`
- Build WASM: `zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`
- Test: `zig build test-lib-vt -Dtest-filter=<filter>`
  - Prefer this when the change is in a libghostty-vt file
- All C enums in `include/ghostty/vt/` must have a `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE`
  sentinel as the last entry to force int enum sizing (pre-C23 portability).

## Directory Structure

- Shared Zig core: `src/`
- macOS app: `macos/`
- GTK (Linux and FreeBSD) app: `src/apprt/gtk`
- Native Windows app: `src/apprt/win32/`
- Windows integration tests: `test/win32/`
- Windows resources and packaging: `dist/windows/`

## Windows Development

- Use the minimum Zig version declared in `build.zig.zon`. The Windows CI
  workflow pins the same version.
- Build on Windows or from Linux/WSL with:
  `zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu`.
  The explicit GNU ABI avoids requiring Visual Studio and Windows SDK headers
  and is the target exercised by Windows CI.
- Build a release with the same options plus `-Doptimize=ReleaseFast`.
  Add `-Dwindows-console=true` when release-mode stderr/stdout is needed.
- Run the Windows compile and Zig tests with
  `zig build test -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu`.
- Run the Win32 integration suite from WSL with
  `bash test/win32/ghostty_test.sh all`. Add a focused automated test for
  each new Windows feature instead of relying only on manual verification.
- Launch automated tests from a local Windows path such as `%TEMP%`, not a
  WSL UNC path. The test harness handles this for the main executable.
- The Windows config is `%LOCALAPPDATA%\ghostty\config.ghostty`; the legacy
  filename `config` is also loaded.

### Windows Resources and Packaging

- Create the portable release ZIP with `bash dist/windows/package.sh`.
- Keep `ghostty.exe` and the `share/` tree in the packaged relative layout.
  `share/terminfo/ghostty.terminfo` is the resource-directory sentinel;
  omitting it causes bundled themes and shell integration discovery to fail.
- The package script produces
  `dist/windows/ghostty-windows-x64-<version>.zip`.
- Windows release tags use `win-vX.Y.Z` so they do not collide with upstream
  `vX.Y.Z` tags. Build from the exact release tag so the binary and ZIP obtain
  the intended semantic version.
- For a release, update `CHANGELOG.md` and all numeric/string version fields in
  `dist/windows/ghostty.rc`, commit those changes, create and push the annotated
  `win-vX.Y.Z` tag, package and test that tagged commit, then attach the ZIP to
  the matching GitHub release. Publishing is a maintainer operation.

### Win32 Implementation Notes

- Win32 messages can arrive during initialization and destruction API calls.
  Any handler that touches a core surface must respect its readiness/lifetime
  guard.
- A WGL context can be current on only one thread at a time. Release it from
  the main thread before the renderer thread acquires it.
- POSIX types may be unusable on Windows; in particular, do not use
  `posix.pid_t` to represent a Windows process handle.
- When debugging an unexpected message-loop exit, check startup calls to
  `PostQuitMessage`; the quit state persists in the thread message queue until
  consumed.

## Issue and PR Guidelines

- GitHub issues and pull requests are welcome.
- Before opening an issue, search existing issues to avoid duplicates and
  include clear reproduction steps, expected behavior, and relevant system
  details.
- Keep pull requests focused, explain the user-visible impact, and include
  tests for behavioral changes when practical.
