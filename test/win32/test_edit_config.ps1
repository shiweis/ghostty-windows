param([string]$BuildDir = (Join-Path $PSScriptRoot '..\..\zig-out'))

# Accept both zig-out/bin and the flat portable distribution. Use a local
# executable, editor, and config fixture for every invocation.
$ErrorActionPreference = 'Stop'
$build = (Get-Item -LiteralPath $BuildDir).FullName
$bin = if (Test-Path -LiteralPath (Join-Path $build 'ghostty.exe')) { $build } else { Join-Path $build 'bin' }
$root = Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('ghostty-edit-config-' + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $root 'Portable Ghostty'
$editorDir = Join-Path $root 'Fake Editor [tools] & 100%'
$xdg = Join-Path $root ('Config [one] & 100% # ' + [char]0x96ea)
$config = Join-Path $xdg 'ghostty\config.ghostty'
$exe = Join-Path $stage 'ghostty.exe'
$editor = Join-Path $editorDir 'Editor Probe.exe'
$record = Join-Path $root 'editor-arguments.txt'
$utf8 = New-Object Text.UTF8Encoding($false)

function Invoke-EditorCase([hashtable]$editors) {
    if (Test-Path -LiteralPath $record) { [IO.File]::Delete($record) }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $exe
    $start.Arguments = '+edit-config'
    $start.WorkingDirectory = $stage
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardErrorEncoding = $utf8
    $envs = $start.EnvironmentVariables
    $envs.Remove('VISUAL')
    $envs.Remove('EDITOR')
    foreach ($key in $editors.Keys) { $envs[$key] = $editors[$key] }
    $envs['XDG_CONFIG_HOME'] = $xdg
    $envs['LOCALAPPDATA'] = Join-Path $root 'Local AppData'
    $envs['APPDATA'] = Join-Path $root 'Roaming AppData'
    $envs['GHOSTTY_RESOURCES_DIR'] = Join-Path $stage 'share\ghostty'
    $envs['GHOSTTY_EDITOR_PROBE_RECORD'] = $record
    $proc = [Diagnostics.Process]::Start($start)
    try {
        $stderr = $proc.StandardError.ReadToEndAsync()
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        if (-not $proc.WaitForExit(15000)) {
            $proc.Kill()
            throw 'Timed out waiting for +edit-config.'
        }
        return @{ExitCode=$proc.ExitCode; Error=$stderr.GetAwaiter().GetResult(); Output=$stdout.GetAwaiter().GetResult()}
    } finally { $proc.Dispose() }
}

function Check-EditorArgs($result, [int]$exitCode, [string[]]$expected) {
    if ($result.ExitCode -ne $exitCode -or -not (Test-Path -LiteralPath $record)) {
        throw "Expected editor exit $exitCode and a recorded invocation; got $($result.ExitCode). $($result.Error)"
    }
    $actual = @([IO.File]::ReadAllLines($record) | ForEach-Object { $utf8.GetString([Convert]::FromBase64String($_)) })
    if ($actual.Count -ne $expected.Count) { throw "Expected $($expected.Count) editor arguments, got $($actual.Count)." }
    for ($i = 0; $i -lt $expected.Count; $i++) {
        if ($i -eq $expected.Count - 1) {
            # Config discovery may use either Windows path separator.
            if (-not [IO.File]::Exists($actual[$i])) { throw "Editor received an inaccessible config path '$($actual[$i])'." }
            $actual[$i] = [IO.Path]::GetFullPath($actual[$i])
        }
        if ($actual[$i] -cne $expected[$i]) { throw "Editor argument $i was '$($actual[$i])', expected '$($expected[$i])'." }
    }
}

try {
    foreach ($dir in @($stage, $editorDir, (Split-Path -Parent $config))) { [void][IO.Directory]::CreateDirectory($dir) }
    foreach ($name in @('ghostty.exe','conpty.dll','OpenConsole.exe')) {
        Copy-Item -LiteralPath (Join-Path $bin $name) -Destination $stage
    }
    foreach ($name in @('ghostty\themes','ghostty\shell-integration','terminfo\ghostty.terminfo')) {
        $relative = Join-Path 'share' $name
        $destination = Join-Path $stage $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        Copy-Item -LiteralPath (Join-Path $build $relative) -Destination $destination -Recurse
    }
    [IO.File]::WriteAllText($config, "font-size = 13" + [Environment]::NewLine, $utf8)

    # Use a real executable under a path with shell metacharacters. It
    # records the exact argv seen by Main and never writes to a config file.
    $editorSource = Join-Path $editorDir 'probe.cs'
    [IO.File]::WriteAllText($editorSource, @'
using System;
using System.IO;
using System.Text;

class EditorProbe {
    static int Main(string[] args) {
        var lines = Array.ConvertAll(args, s => Convert.ToBase64String(Encoding.UTF8.GetBytes(s)));
        File.WriteAllLines(Environment.GetEnvironmentVariable("GHOSTTY_EDITOR_PROBE_RECORD"), lines);
        return Array.IndexOf(args, "--exit-37") >= 0 ? 37 : 0;
    }
}
'@, $utf8)
    $compiler = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
    if (-not (Test-Path -LiteralPath $compiler)) {
        $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    }
    & $compiler /nologo /target:exe "/out:$editor" $editorSource
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the temporary Windows editor probe.' }

    $visual = '"' + $editor + '" --visual "argument & one"'
    $fallback = '"' + $editor + '" --editor --exit-37 "C:\folder with spaces\file" ""'
    $result = Invoke-EditorCase @{VISUAL=$visual;EDITOR=$fallback}
    Check-EditorArgs $result 0 @('--visual','argument & one',$config)
    Write-Output 'PASS: VISUAL takes precedence and the quoted executable, editor option, and Unicode config path reach the editor intact.'

    foreach ($envs in @(@{EDITOR=$fallback}, @{VISUAL="  "; EDITOR=$fallback})) {
        $result = Invoke-EditorCase $envs
        Check-EditorArgs $result 37 @('--editor','--exit-37','C:\folder with spaces\file','',$config)
    }
    Write-Output 'PASS: missing or blank VISUAL uses EDITOR, preserves quoted and empty arguments, and propagates editor exit 37.'

    $result = Invoke-EditorCase @{}
    if ($result.ExitCode -ne 1 -or -not $result.Error.Contains('$EDITOR or $VISUAL') -or
        -not $result.Error.Replace('/', '\').Contains($config) -or (Test-Path -LiteralPath $record)) {
        throw "Missing-editor diagnostic failed ($($result.ExitCode)): $($result.Error)"
    }
    Write-Output 'PASS: missing editor settings report the controlled config path and exit 1.'

    $missing = Join-Path $editorDir 'does not exist.exe'
    $result = Invoke-EditorCase @{VISUAL=('"' + $missing + '" --example'); EDITOR=$fallback}
    if ($result.ExitCode -ne 1 -or -not $result.Error.Contains('Unable to start the editor') -or
        -not $result.Error.Contains($missing) -or (Test-Path -LiteralPath $record)) {
        throw "Missing-executable diagnostic failed ($($result.ExitCode)): $($result.Error)"
    }
    Write-Output 'PASS: a configured but nonexistent VISUAL reports the failed command and exits 1.'
} finally {
    if (Test-Path -LiteralPath $root) {
        $expectedParent = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
        $actual = (Get-Item -LiteralPath $root).FullName
        if ([IO.Path]::GetDirectoryName($actual) -ne $expectedParent -or [IO.Path]::GetFileName($actual) -notmatch '^ghostty-edit-config-[a-f0-9]{32}$') {
            throw "Unexpected test directory '$actual'."
        }
        Remove-Item -LiteralPath $actual -Recurse -Force
    }
}
