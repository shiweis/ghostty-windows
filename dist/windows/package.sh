#!/bin/bash
# Build and package Ghostty for Windows as a portable ZIP.
#
# Usage:
#   ./dist/windows/package.sh              # fast, x86_64
#   ./dist/windows/package.sh debug        # Debug build (Console subsystem)
#   ./dist/windows/package.sh --candidate 1.4.0-rc.1  # local prerelease + commit
#   ./dist/windows/package.sh --release    # exact, clean annotated win-vX.Y.Z
#
# Output: dist/windows/ghostty-windows-x64-<version>.zip

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OPTIMIZE=fast
RELEASE=false
CANDIDATE=""
usage() {
    echo 'Usage: bash dist/windows/package.sh [fast|debug|safe|small] [--release | --candidate X.Y.Z-PRERELEASE]' >&2
    exit 2
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        fast|debug|safe|small) OPTIMIZE="$1" ;;
        --release) RELEASE=true ;;
        --candidate)
            if [ "$#" -lt 2 ] || [ -z "$2" ] || [ -n "$CANDIDATE" ]; then usage; fi
            CANDIDATE="$2"
            shift
            ;;
        *) usage ;;
    esac
    shift
done

cd "$REPO_DIR"

valid_candidate() {
    local LC_ALL=C
    local number='(0|[1-9][0-9]*)'
    # Numeric prerelease identifiers follow the core's leading-zero rule.
    local identifier="($number|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
    local metadata='([+][0-9A-Za-z-]+([.][0-9A-Za-z-]+)*)?'
    local pattern="^${number}[.]${number}[.]${number}-${identifier}([.]${identifier})*${metadata}$"
    [[ "$1" =~ $pattern ]]
}

RELEASE_VERSION=""
CANDIDATE_VERSION=""
BUILD_ARGS=(-Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu "-Doptimize=$OPTIMIZE")
if [ -n "$CANDIDATE" ]; then
    if [ "$RELEASE" = true ]; then usage; fi
    if ! valid_candidate "$CANDIDATE"; then
        echo "Invalid candidate prerelease version: $CANDIDATE" >&2
        exit 2
    fi
    COMMIT="$(git rev-parse --short HEAD)"
    if [[ "$CANDIDATE" == *+* ]]; then
        CANDIDATE_VERSION="$CANDIDATE.$COMMIT"
    else
        CANDIDATE_VERSION="$CANDIDATE+$COMMIT"
    fi
    BUILD_ARGS+=("-Dversion-string=$CANDIDATE_VERSION")
fi
if [ "$RELEASE" = true ]; then
    if [ "$OPTIMIZE" != fast ]; then
        echo 'Release packages require fast optimization.' >&2
        exit 1
    fi
    RELEASE_TAG="$(git describe --exact-match --tags --match 'win-v*' 2>/dev/null)" || {
        echo 'Release packages require an exact annotated win-vX.Y.Z tag.' >&2
        exit 1
    }
    if [[ ! "$RELEASE_TAG" =~ ^win-v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        [ "$(git cat-file -t "$RELEASE_TAG")" != tag ]; then
        echo 'Release packages require an exact annotated win-vX.Y.Z tag.' >&2
        exit 1
    fi
    if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
        echo 'Release packages require a clean working tree.' >&2
        exit 1
    fi
    RELEASE_VERSION="${RELEASE_TAG#win-v}"
fi

if ! command -v powershell.exe >/dev/null; then
    echo 'Packaging requires Windows PowerShell to validate the executable and PE version resources.' >&2
    exit 1
fi
windows_path() {
    if command -v wslpath >/dev/null; then wslpath -w "$1"
    elif command -v cygpath >/dev/null; then cygpath -w "$1"
    else printf '%s\n' "$1"
    fi
}

echo "Building ghostty (optimize=$OPTIMIZE)..."
bash "$SCRIPT_DIR/build.sh" "${BUILD_ARGS[@]}"

for resource in bin/ghostty.exe bin/conpty.dll bin/OpenConsole.exe share/terminfo/ghostty.terminfo share/licenses/conpty/LICENSE.txt share/ghostty/shell-integration/powershell/ghostty-shell-integration.ps1; do
    if [ ! -f "zig-out/$resource" ]; then
        echo "ERROR: Incomplete Windows build — zig-out/$resource not found" >&2
        exit 1
    fi
done
for resource in share/ghostty/themes share/ghostty/shell-integration; do
    if [ ! -d "zig-out/$resource" ] || [ -z "$(find "zig-out/$resource" -type f -print -quit)" ]; then
        echo "ERROR: Incomplete Windows build — zig-out/$resource missing or empty" >&2
        exit 1
    fi
done

# Validate the built binary rather than guessing its version from nearby tags.
VERIFY_SCRIPT="$(windows_path "$SCRIPT_DIR/verify-build.ps1")"
VERSION="$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$VERIFY_SCRIPT" -BuildDir "$(windows_path "$REPO_DIR/zig-out")" | tr -d '\r')"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$ ]]; then
    echo 'ERROR: Payload validation did not return a semantic executable version.' >&2
    exit 1
fi
if [ "$RELEASE" = true ] && [ "$VERSION" != "$RELEASE_VERSION" ]; then
    echo "ERROR: Executable version $VERSION does not match release tag $RELEASE_TAG." >&2
    exit 1
fi
if [ -n "$CANDIDATE_VERSION" ] && [ "$VERSION" != "$CANDIDATE_VERSION" ]; then
    echo "ERROR: Executable version $VERSION does not match requested candidate $CANDIDATE_VERSION." >&2
    exit 1
fi
echo "Version: $VERSION"

# Create staging directory
STAGE_DIR="$REPO_DIR/dist/windows/_stage/ghostty"
rm -rf "$REPO_DIR/dist/windows/_stage"
mkdir -p "$STAGE_DIR"
trap 'rm -rf "$REPO_DIR/dist/windows/_stage"' EXIT
cp LICENSE "$STAGE_DIR/LICENSE"

# Keep the matching console runtime pair beside the executable.
for binary in ghostty.exe conpty.dll OpenConsole.exe; do
    cp "zig-out/bin/$binary" "$STAGE_DIR/"
    echo "  $binary"
done
mkdir -p "$STAGE_DIR/share/licenses/conpty"
cp zig-out/share/licenses/conpty/LICENSE.txt "$STAGE_DIR/share/licenses/conpty/"
echo "  share/licenses/conpty/LICENSE.txt"

# Copy share resources (themes, shell-integration)
if [ -d zig-out/share/ghostty ]; then
    mkdir -p "$STAGE_DIR/share/ghostty"
    cp -r zig-out/share/ghostty/themes "$STAGE_DIR/share/ghostty/"
    cp -r zig-out/share/ghostty/shell-integration "$STAGE_DIR/share/ghostty/"
    THEME_COUNT=$(ls "$STAGE_DIR/share/ghostty/themes/" 2>/dev/null | wc -l)
    echo "  share/ghostty/themes/ ($THEME_COUNT themes)"
    echo "  share/ghostty/shell-integration/"
fi

# Copy the terminfo source file. resourcesDir() (src/os/resourcesdir.zig)
# uses share/terminfo/ghostty.terminfo as the Windows sentinel; without it,
# theme loading silently fails on fresh extracts. The compiled terminfo
# tree contains symlinks Windows ZIP tools can't handle, so we ship only
# the plain-text source — native Windows apps don't read terminfo anyway,
# and WSL/SSH users get terminfo from the Linux side.
if [ -f zig-out/share/terminfo/ghostty.terminfo ]; then
    mkdir -p "$STAGE_DIR/share/terminfo"
    cp zig-out/share/terminfo/ghostty.terminfo "$STAGE_DIR/share/terminfo/"
    echo "  share/terminfo/ghostty.terminfo (resource sentinel)"
fi

# Create a minimal README
cat > "$STAGE_DIR/README.txt" << READMEEOF
Ghostty for Windows — $VERSION
https://github.com/shiweis/ghostty-windows

QUICK START
  1. Run ghostty.exe
  2. Config file: %LOCALAPPDATA%\\ghostty\\config.ghostty
     (the legacy filename "config" is also supported)
  Keep conpty.dll and OpenConsole.exe beside ghostty.exe.

KEYBOARD SHORTCUTS
  Ctrl+Shift+T        New tab
  Ctrl+Shift+W        Close tab/pane
  Ctrl+Shift+N        New window
  Ctrl+Shift+P        Command palette
  Ctrl+Shift+O        Split right
  Ctrl+Shift+E        Split down
  Ctrl+Shift+[ / ]    Navigate splits
  Ctrl+Shift+C / V    Copy / Paste
  Ctrl+Shift+F        Find
  Ctrl+Enter          Toggle fullscreen
  Ctrl+= / - / 0      Zoom in / out / reset
  Ctrl+,              Open config file

SHELL INTEGRATION (PowerShell)
  Windows PowerShell 5.1 (powershell.exe) and PowerShell 7 (pwsh.exe)
  load the bundled integration automatically when enabled.
  No PowerShell profile edit is required. Keep the share/ folder beside
  ghostty.exe wherever you extract this portable package.
  The script is share/ghostty/shell-integration/powershell/ghostty-shell-integration.ps1.
  To disable integration, set shell-integration = none in your config.

For full documentation: https://ghostty.org/docs
READMEEOF
echo "  README.txt"

# Check the flattened portable layout as well as the build prefix.
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$VERIFY_SCRIPT" -BuildDir "$(windows_path "$STAGE_DIR")" \
    -Portable -ExpectedVersion "$VERSION" >/dev/null

# Create ZIP
ZIP_NAME="ghostty-windows-x64-${VERSION}.zip"
ZIP_PATH="$REPO_DIR/dist/windows/$ZIP_NAME"
rm -f "$ZIP_PATH"
cd "$REPO_DIR/dist/windows/_stage"
if command -v zip &>/dev/null; then
    zip -qr "$ZIP_PATH" ghostty/
else
    # PowerShell can't zip from WSL UNC paths. Copy to Windows temp first.
    WIN_TEMP="$(cmd.exe /c "echo %TEMP%" 2>/dev/null | tr -d '\r')"
    WIN_TEMP_WSL="$(wslpath "$WIN_TEMP")"
    rm -rf "$WIN_TEMP_WSL/ghostty-zip-stage"
    mkdir -p "$WIN_TEMP_WSL/ghostty-zip-stage"
    cp -r "$REPO_DIR/dist/windows/_stage/ghostty" "$WIN_TEMP_WSL/ghostty-zip-stage/ghostty"
    powershell.exe -Command "Compress-Archive -Path '${WIN_TEMP}\\ghostty-zip-stage\\ghostty' -DestinationPath '${WIN_TEMP}\\${ZIP_NAME}' -Force" 2>&1 | tr -d '\r'
    cp "$WIN_TEMP_WSL/$ZIP_NAME" "$ZIP_PATH" 2>/dev/null
    rm -rf "$WIN_TEMP_WSL/ghostty-zip-stage" "$WIN_TEMP_WSL/$ZIP_NAME"
fi

# Clean up staging
rm -rf "$REPO_DIR/dist/windows/_stage"

if [ -f "$ZIP_PATH" ]; then
    SIZE=$(du -h "$ZIP_PATH" | cut -f1)
    echo ""
    echo "Package created: dist/windows/$ZIP_NAME ($SIZE)"
else
    echo "ERROR: Failed to create ZIP"
    exit 1
fi
