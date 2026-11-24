param(
    [Parameter(Mandatory = $true)][string]$BuildDir,
    [string]$ExpectedVersion = '',
    [switch]$Portable
)

# Validate the payload that will actually ship. Capture CLI output through pipes
# so Windows-subsystem release executables are waited for just like console apps.
$ErrorActionPreference = 'Stop'
$BuildDir = (Get-Item -LiteralPath $BuildDir).FullName
$binaryDir = if ($Portable) { $BuildDir } else { Join-Path $BuildDir 'bin' }
$binaries = @('ghostty.exe', 'conpty.dll', 'OpenConsole.exe')
foreach ($name in $binaries) {
    if (-not (Test-Path -LiteralPath (Join-Path $binaryDir $name) -PathType Leaf)) {
        throw "Incomplete Windows payload: missing $name"
    }
}
$required = @(
    'share\terminfo\ghostty.terminfo', 'share\licenses\conpty\LICENSE.txt',
    'share\ghostty\shell-integration\powershell\ghostty-shell-integration.ps1',
    'share\ghostty\shell-integration\powershell\ghostty-ssh.ps1',
    'share\ghostty\shell-integration\powershell\ssh.ps1'
)
if ($Portable) { $required += @('README.txt', 'LICENSE') }
foreach ($relativePath in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $BuildDir $relativePath) -PathType Leaf)) {
        throw "Incomplete Windows payload: missing $relativePath"
    }
}
foreach ($relativePath in @('share\ghostty\themes', 'share\ghostty\shell-integration')) {
    $directory = Join-Path $BuildDir $relativePath
    if (-not (Test-Path -LiteralPath $directory -PathType Container) -or
        -not (Get-ChildItem -LiteralPath $directory -Recurse -File | Select-Object -First 1)) {
        throw "Incomplete Windows payload: missing or empty $relativePath"
    }
}

# The checkout may live at a WSL UNC path. Run only this validation process from
# a local directory, keeping the matching Microsoft console runtime beside it.
$versionDir = Join-Path $env:TEMP ('ghostty-version-' + [guid]::NewGuid().ToString('N'))
$child = $null
try {
    New-Item -ItemType Directory -Path $versionDir | Out-Null
    foreach ($name in $binaries) {
        Copy-Item -LiteralPath (Join-Path $binaryDir $name) -Destination (Join-Path $versionDir $name)
    }
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $versionDir 'ghostty.exe'
    $start.Arguments = '--version'
    $start.WorkingDirectory = $versionDir
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $child = New-Object System.Diagnostics.Process
    $child.StartInfo = $start
    if (-not $child.Start()) { throw 'Could not start ghostty --version.' }
    $stdout = $child.StandardOutput.ReadToEndAsync()
    $stderr = $child.StandardError.ReadToEndAsync()
    if (-not $child.WaitForExit(30000)) {
        $child.Kill()
        $child.WaitForExit()
        throw 'ghostty --version timed out.'
    }
    if ($child.ExitCode -ne 0) { throw "ghostty --version failed: $($stderr.Result)" }
    $match = [regex]::Match($stdout.Result, '(?m)^Ghostty ([^\r\n]+)\r?$')
    if (-not $match.Success) { throw 'ghostty --version did not report a version.' }
    $version = $match.Groups[1].Value
    $semantic = [regex]::Match($version, '^(\d+)\.(\d+)\.(\d+)(?:[-+][0-9A-Za-z.+-]+)?$')
    if (-not $semantic.Success) { throw "Invalid executable version: $version" }
    if ($ExpectedVersion -and $version -cne $ExpectedVersion) {
        throw "Executable version $version does not match expected version $ExpectedVersion."
    }

    $numeric = '{0}.{1}.{2}.0' -f $semantic.Groups[1].Value, $semantic.Groups[2].Value, $semantic.Groups[3].Value
    $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($start.FileName)
    $fileNumeric = '{0}.{1}.{2}.{3}' -f $info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart
    $productNumeric = '{0}.{1}.{2}.{3}' -f $info.ProductMajorPart, $info.ProductMinorPart, $info.ProductBuildPart, $info.ProductPrivatePart
    if ($info.FileVersion -cne $numeric -or $info.ProductVersion -cne $numeric -or
        $fileNumeric -cne $numeric -or $productNumeric -cne $numeric) {
        throw "PE version resources do not match executable version $version (expected $numeric)."
    }
    Write-Output $version
} finally {
    if ($null -ne $child) { $child.Dispose() }
    if (Test-Path -LiteralPath $versionDir) { Remove-Item -LiteralPath $versionDir -Recurse -Force }
}
