param([string]$BuildDir = (Join-Path $PSScriptRoot '..\..\zig-out'))

# No GUI or global input: exercise payload and executable/PE version validation.
$ErrorActionPreference = 'Stop'
$verify = Join-Path $PSScriptRoot '..\..\dist\windows\verify-build.ps1'
$BuildDir = (Get-Item -LiteralPath $BuildDir).FullName
$version = & $verify -BuildDir $BuildDir
if (-not $version) { throw 'Build validation returned no version.' }
# Upstream uses a colon between each theme and variant name. Windows build
# hosts and cross builds must produce the same loadable filenames.
foreach ($theme in 'Analog Heartbeat Phosphor', 'Neon Raincheck After Hours', 'Paper Crane Midnight Ink') {
    $path = Join-Path $BuildDir "share\ghostty\themes\$theme"
    if (-not (Select-String -LiteralPath $path -Pattern '^palette = 0=' -Quiet)) {
        throw "Bundled theme has no palette: $theme"
    }
}
$testRoot = Join-Path $env:TEMP ('ghostty-package-test-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $files = @(
        'bin\ghostty.exe', 'bin\conpty.dll', 'bin\OpenConsole.exe',
        'share\terminfo\ghostty.terminfo', 'share\licenses\conpty\LICENSE.txt',
        'share\ghostty\shell-integration\powershell\ghostty-shell-integration.ps1'
    )
    foreach ($relative in $files) {
        $destination = Join-Path $testRoot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $BuildDir $relative) -Destination $destination
    }
    $themes = Join-Path $testRoot 'share\ghostty\themes'
    New-Item -ItemType Directory -Path $themes | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $themes 'Fixture Theme'), 'background = #123456')
    if ((& $verify -BuildDir $testRoot -ExpectedVersion $version) -cne $version) {
        throw 'Complete build failed verification.'
    }

    foreach ($relative in $files) {
        $path = Join-Path $testRoot $relative
        $saved = Join-Path $testRoot 'saved-file'
        Move-Item -LiteralPath $path -Destination $saved
        try {
            $rejected = $false
            try { & $verify -BuildDir $testRoot | Out-Null }
            catch { $rejected = $_ -match 'Incomplete Windows payload' }
            if (-not $rejected) { throw "Missing $relative was not rejected." }
        } finally { Move-Item -LiteralPath $saved -Destination $path }
    }
    Remove-Item -LiteralPath (Join-Path $themes 'Fixture Theme')
    $rejected = $false
    try { & $verify -BuildDir $testRoot | Out-Null }
    catch { $rejected = $_ -match 'missing or empty' }
    if (-not $rejected) { throw 'An empty themes directory was not rejected.' }
    [System.IO.File]::WriteAllText((Join-Path $themes 'Fixture Theme'), 'background = #123456')

    $rejected = $false
    try { & $verify -BuildDir $testRoot -ExpectedVersion '0.0.0-unexpected' | Out-Null }
    catch { $rejected = $_ -match 'does not match expected version' }
    if (-not $rejected) { throw 'Mismatched executable version was not rejected.' }

    # Flatten bin/ exactly as the ZIP does and validate the portable payload.
    Get-ChildItem -LiteralPath (Join-Path $testRoot 'bin') -File | Move-Item -Destination $testRoot
    Remove-Item -LiteralPath (Join-Path $testRoot 'bin')
    [System.IO.File]::WriteAllText((Join-Path $testRoot 'README.txt'), 'fixture readme')
    [System.IO.File]::WriteAllText((Join-Path $testRoot 'LICENSE'), 'fixture license')
    if ((& $verify -BuildDir $testRoot -Portable -ExpectedVersion $version) -cne $version) {
        throw 'Portable layout failed verification.'
    }
    Write-Output "PowerShell $($PSVersionTable.PSVersion) package validation checks passed ($version)."
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
