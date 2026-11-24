# Ghostty Shell Integration for PowerShell
#
# This script provides terminal integration features when running inside
# Ghostty. It is automatically sourced when shell-integration is enabled.
#
# Features (controlled by $env:GHOSTTY_SHELL_FEATURES):
#   - Semantic prompt marking (OSC 133)
#   - Current working directory reporting (OSC 7)
#   - Window title updates (OSC 2)
#   - Cursor shape changes at prompt
#   - Ghostty binary directory on PATH
#   - SSH environment forwarding and remote terminfo installation

if (-not $env:GHOSTTY_SHELL_FEATURES) { return }

$GhosttyFeatures = $env:GHOSTTY_SHELL_FEATURES -split ','

if ($GhosttyFeatures -contains 'path' -and $env:GHOSTTY_BIN_DIR) {
    & {
        $separator = [System.IO.Path]::PathSeparator
        $binDir = $env:GHOSTTY_BIN_DIR.Replace('/', '\').TrimEnd('\')
        foreach ($entry in ($env:PATH -split $separator)) {
            if ($entry.Trim('"').Replace('/', '\').TrimEnd('\') -ieq $binDir) { return }
        }
        if ($env:PATH) { $env:PATH += $separator + $env:GHOSTTY_BIN_DIR }
        else { $env:PATH = $env:GHOSTTY_BIN_DIR }
    }
}

if ($env:GHOSTTY_BIN_DIR -and ($GhosttyFeatures -contains 'ssh-env' -or $GhosttyFeatures -contains 'ssh-terminfo')) {
    # An external script preserves both $? and LASTEXITCODE when SSH fails.
    if (-not (Test-Path Alias:ssh)) {
        Set-Alias -Name ssh -Value (Join-Path $PSScriptRoot 'ssh.ps1')
    }
}

# Save the original prompt function so we can call it.
if (-not (Test-Path Function:\__ghostty_original_prompt)) {
    if (Test-Path Function:\prompt) {
        $Function:__ghostty_original_prompt = $Function:prompt
    } else {
        function __ghostty_original_prompt { "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) " }
    }
}

# Track prompt state for OSC 133 sequencing.
$Script:__ghostty_prompt_state = 'initial'
# Windows PowerShell 5.1 does not recognize the backtick-e escape sequence.
# Construct ESC explicitly so both powershell.exe and pwsh.exe emit real VT.
$Script:__ghostty_escape = [char]27

function prompt {
    # Capture exit code before anything else can clobber it.
    $realLASTEXITCODE = $global:LASTEXITCODE
    $cmdSuccess = $?

    # OSC 133;D — end of previous command output (with exit status).
    # Skip on the very first prompt (no command has run yet).
    if ($Script:__ghostty_prompt_state -ne 'initial') {
        $exitCode = if ($cmdSuccess) { 0 } else { if ($realLASTEXITCODE) { $realLASTEXITCODE } else { 1 } }
        [Console]::Write("$Script:__ghostty_escape]133;D;$exitCode`a")
    }

    # OSC 133;A — fresh line / new prompt.
    [Console]::Write("$Script:__ghostty_escape]133;A`a")

    # setupFeatures emits the configured blink state with the cursor feature.
    # Retain the bare name for manually configured older integrations.
    if ($GhosttyFeatures -contains 'cursor:steady') {
        [Console]::Write("$Script:__ghostty_escape[6 q")
    } elseif ($GhosttyFeatures -contains 'cursor:blink' -or $GhosttyFeatures -contains 'cursor') {
        [Console]::Write("$Script:__ghostty_escape[5 q")
    }

    # OSC 7 — report current working directory.
    # A provider or PSDrive name can contain control characters even when a
    # Windows filesystem path cannot. Keep those bytes out of OSC payloads so
    # navigating to such a location cannot inject terminal commands.
    $location = Get-Location
    $cwd = $location.ProviderPath -replace '\\', '/' -replace '\p{Cc}', ''
    $cwd = [Uri]::EscapeDataString($cwd).Replace('%2F', '/').Replace('%3A', ':')
    # File URI: file://hostname/path
    $hostname = [System.Net.Dns]::GetHostName() -replace '\p{Cc}', ''
    [Console]::Write("$Script:__ghostty_escape]7;file://$hostname/$cwd`a")

    # OSC 2 — window title (current directory).
    if ($GhosttyFeatures -contains 'title') {
        $leaf = (Split-Path -Leaf (Get-Location)) -replace '\p{Cc}', ''
        [Console]::Write("$Script:__ghostty_escape]2;$leaf`a")
    }

    # Call the original prompt to get the prompt string.
    $promptText = __ghostty_original_prompt

    # OSC 133;B — end of prompt, start of user input.
    [Console]::Write("$Script:__ghostty_escape]133;B`a")

    $Script:__ghostty_prompt_state = 'prompt-end'

    # Restore LASTEXITCODE so the user sees the real value.
    $global:LASTEXITCODE = $realLASTEXITCODE

    return $promptText
}

# PSReadLine key handler to emit OSC 133;C when Enter is pressed
# (marks end of input, start of command output).
if (Get-Module -Name PSReadLine -ErrorAction SilentlyContinue) {
    Set-PSReadLineKeyHandler -Key Enter -ScriptBlock {
        # OSC 133;C — end of input, start of output.
        [Console]::Write("$Script:__ghostty_escape]133;C`a")

        # Reset cursor to default shape before command runs.
        if ($GhosttyFeatures -contains 'cursor:blink' -or
            $GhosttyFeatures -contains 'cursor:steady' -or
            $GhosttyFeatures -contains 'cursor') {
            [Console]::Write("$Script:__ghostty_escape[0 q")
        }

        $Script:__ghostty_prompt_state = 'pre-exec'

        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    }
}

# Clean up the integration env vars (don't leak to child processes).
Remove-Item Env:GHOSTTY_SHELL_INTEGRATION_XDG_DIR -ErrorAction SilentlyContinue
