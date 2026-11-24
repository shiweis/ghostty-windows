param(
    [string]$IntegrationPath = (Join-Path $PSScriptRoot '..\..\src\shell-integration\powershell\ghostty-shell-integration.ps1')
)

# Run in a fresh powershell.exe or pwsh.exe process with -NoProfile. This test
# captures VT output in memory and never launches a GUI or injects input.
$ErrorActionPreference = 'Stop'

function Assert-True($condition, $description) {
    if (-not $condition) { throw $description }
    Write-Output "PASS=$description"
}

# Use an inert PSReadLine endpoint so the registered Enter handler itself can
# run without ever accepting input. A fresh noninteractive engine has not
# loaded the real assembly; refuse to replace it if this test was sourced.
if ('Microsoft.PowerShell.PSConsoleReadLine' -as [type]) {
    throw 'Run shell integration tests in a fresh noninteractive PowerShell process.'
}
Add-Type @'
namespace Microsoft.PowerShell {
    public static class PSConsoleReadLine {
        public static int AcceptLineCalls;
        public static void AcceptLine() { AcceptLineCalls++; }
    }
}
'@

# Capture registration without loading PSReadLine or accepting console input.
function Get-Module {
    param([string]$Name, [string]$ErrorAction)
    if ($Name -ne 'PSReadLine') { throw "Unexpected module lookup: $Name" }
    return [pscustomobject]@{ Name = 'PSReadLine' }
}
function Set-PSReadLineKeyHandler {
    param([string]$Key, [scriptblock]$ScriptBlock)
    if ($Key -ne 'Enter') { throw "Unexpected key handler: $Key" }
    $Script:enterHandler = $ScriptBlock
}
function prompt { 'ghostty-test> ' }

$originalOutput = [Console]::Out
$originalFeatures = $env:GHOSTTY_SHELL_FEATURES
$originalExitCode = $global:LASTEXITCODE
$capture = New-Object System.IO.StringWriter
$Script:enterHandler = $null
try {
    [Console]::SetOut($capture)
    # This is the actual value produced by setupFeatures with blinking enabled.
    $env:GHOSTTY_SHELL_FEATURES = 'cursor:blink,path,ssh-env,ssh-terminfo,sudo,title'
    . $IntegrationPath

    $firstPrompt = prompt
    $firstOutput = $capture.ToString()
    $capture.GetStringBuilder().Clear() | Out-Null

    $global:LASTEXITCODE = 37
    $secondPrompt = prompt
    $secondOutput = $capture.ToString()
    $preservedExitCode = $global:LASTEXITCODE
    $capture.GetStringBuilder().Clear() | Out-Null

    & $Script:enterHandler
    $blinkEnterOutput = $capture.ToString()
    $capture.GetStringBuilder().Clear() | Out-Null

    # setupFeatures uses :steady when cursor-style-blink is false.
    $GhosttyFeatures = 'cursor:steady,path,ssh-env,ssh-terminfo,sudo,title' -split ','
    $null = prompt
    $steadyOutput = $capture.ToString()
    $capture.GetStringBuilder().Clear() | Out-Null
    & $Script:enterHandler
    $steadyEnterOutput = $capture.ToString()
    $capture.GetStringBuilder().Clear() | Out-Null

    $GhosttyFeatures = @('cursor')
    $null = prompt
    $legacyOutput = $capture.ToString()
    $capture.GetStringBuilder().Clear() | Out-Null

    $GhosttyFeatures = @()
    $Script:__ghostty_prompt_state = 'initial'
    $null = prompt
    $minimalOutput = $capture.ToString()
    $capture.GetStringBuilder().Clear() | Out-Null
    & $Script:enterHandler
    $minimalEnterOutput = $capture.ToString()
    $capture.GetStringBuilder().Clear() | Out-Null

    # PSDrive names can contain terminal controls that Windows rejects in
    # ordinary filenames. Exercise a real provider location, keeping the VT
    # output captured so the test never touches the desktop clipboard.
    $unicodeName = [string][char]0x6d4b + [char]0x8bd5
    $driveName = 'ghostty-' + $unicodeName + '-' + [guid]::NewGuid().ToString('N') +
        [char]7 + [char]27 + ']52;c;SGVsbG8=' + [char]7 + [char]0x7f + [char]0x9b
    # DEL and C1 controls are valid Windows filename characters. Cover the
    # title's leaf as well as the drive-qualified working directory.
    $directoryName = 'ghostty shell #100%-' + [guid]::NewGuid().ToString('N') + '-' +
        $unicodeName + [char]0x7f + [char]0x9b
    $hostileRoot = Join-Path $env:TEMP $directoryName
    $originalLocation = Get-Location
    try {
        New-Item -ItemType Directory -Path $hostileRoot | Out-Null
        New-PSDrive -Name $driveName -PSProvider FileSystem -Root $hostileRoot | Out-Null
        Set-Location -LiteralPath ($driveName + ':\')
        $hostileCwd = [Uri]::EscapeDataString(((Get-Location).ProviderPath -replace '\\', '/' -replace '\p{Cc}', '')).Replace('%2F', '/').Replace('%3A', ':')
        $hostileLeaf = $directoryName -replace '\p{Cc}', ''
        $GhosttyFeatures = @('title')
        $Script:__ghostty_prompt_state = 'initial'
        $null = prompt
        $hostileOutput = $capture.ToString()
    } finally {
        Set-Location -LiteralPath $originalLocation.Path
        Remove-PSDrive -Name $driveName -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $hostileRoot -ErrorAction SilentlyContinue
    }
} finally {
    [Console]::SetOut($originalOutput)
    $capture.Dispose()
    $env:GHOSTTY_SHELL_FEATURES = $originalFeatures
    $global:LASTEXITCODE = $originalExitCode
}

$esc = [string][char]27
$bel = [string][char]7
$cwd = [Uri]::EscapeDataString(((Get-Location).ProviderPath -replace '\\', '/')).Replace('%2F', '/').Replace('%3A', ':')
$hostname = [System.Net.Dns]::GetHostName()
$leaf = Split-Path -Leaf (Get-Location)
Assert-True ($firstPrompt -eq 'ghostty-test> ' -and $secondPrompt -eq $firstPrompt) 'original prompt text is preserved'
Assert-True ($firstOutput.StartsWith($esc + ']133;A' + $bel)) 'first prompt starts with a real ESC semantic marker'
Assert-True ($firstOutput.Contains($esc + '[5 q') -and -not $firstOutput.Contains($esc + '[6 q')) 'generated blinking cursor feature emits DECSCUSR 5'
Assert-True ($steadyOutput.Contains($esc + '[6 q') -and -not $steadyOutput.Contains($esc + '[5 q')) 'generated steady cursor feature emits DECSCUSR 6'
Assert-True ($blinkEnterOutput -eq ($esc + ']133;C' + $bel + $esc + '[0 q')) 'blinking cursor restores the default before command execution'
Assert-True ($steadyEnterOutput -eq ($esc + ']133;C' + $bel + $esc + '[0 q')) 'steady cursor restores the default before command execution'
Assert-True ($legacyOutput.Contains($esc + '[5 q')) 'legacy bare cursor feature retains blinking-bar behavior'
Assert-True ($firstOutput.Contains($esc + "]7;file://$hostname/$cwd" + $bel)) 'working directory sequence uses a real ESC'
Assert-True ($firstOutput.Contains($esc + "]2;$leaf" + $bel)) 'title sequence uses a real ESC'
Assert-True ($firstOutput.EndsWith($esc + ']133;B' + $bel)) 'prompt end uses a real ESC'
Assert-True ($secondOutput.StartsWith($esc + ']133;D;0' + $bel)) 'subsequent prompt reports command completion'
Assert-True ($preservedExitCode -eq 37) 'LASTEXITCODE is preserved'
Assert-True (-not $minimalOutput.Contains($esc + '[5 q') -and -not $minimalOutput.Contains($esc + '[6 q') -and -not $minimalOutput.Contains($esc + ']2;')) 'optional cursor and title features can be disabled'
Assert-True ($minimalEnterOutput -eq ($esc + ']133;C' + $bel)) 'disabled cursor feature emits no command-start cursor control'
Assert-True ([Microsoft.PowerShell.PSConsoleReadLine]::AcceptLineCalls -eq 3) 'registered Enter handler reaches the inert PSReadLine endpoint'
Assert-True ($null -ne $Script:enterHandler) 'Enter handler is registered without accepting input'
Assert-True (-not $hostileOutput.Contains($esc + ']52;')) 'provider location cannot inject OSC clipboard commands'
Assert-True ($hostileOutput.Contains($esc + "]7;file://$hostname/$hostileCwd" + $bel)) 'provider directory reports strip C0 and C1 controls'
Assert-True ($hostileOutput.Contains($esc + "]2;$hostileLeaf" + $bel)) 'directory titles strip DEL and C1 controls'
Assert-True ($hostileOutput.Contains($unicodeName)) 'directory reports preserve Unicode names'

# Compile a native argv recorder before the app build. Comparing its direct
# and wrapped invocations also checks each engine's native argument passing.
$scratch = Join-Path $env:TEMP ('ghostty shell features ' + [guid]::NewGuid().ToString('N'))
$originalPath = $env:PATH
$originalBin = $env:GHOSTTY_BIN_DIR
$originalRecord = $env:GHOSTTY_TEST_SSH_RECORD
try {
    New-Item -ItemType Directory -Path $scratch | Out-Null
    $source = Join-Path $scratch 'Arguments.cs'
    $probe = Join-Path $scratch 'ghostty.exe'
    $reference = Join-Path $scratch 'ssh-reference.exe'
    [IO.File]::WriteAllText($source, @'
using System;
using System.IO;
using System.Text;
class Arguments {
    static int Main(string[] args) {
        var path = Environment.GetEnvironmentVariable("GHOSTTY_TEST_SSH_RECORD");
        File.WriteAllLines(path, Array.ConvertAll(args, a =>
            Convert.ToBase64String(Encoding.UTF8.GetBytes(a))));
        if (Array.IndexOf(args, "read-stdin") >= 0)
            Console.WriteLine(Console.ReadLine());
        return 37;
    }
}
'@)
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    & $csc /nologo /target:winexe "/out:$probe" $source
    if ($LASTEXITCODE -ne 0) { throw 'Compiling the GUI-subsystem Ghostty stand-in failed.' }
    & $csc /nologo /target:exe "/out:$reference" $source
    if ($LASTEXITCODE -ne 0) { throw 'Compiling the native argument recorder failed.' }
    $env:GHOSTTY_BIN_DIR = $scratch
    $env:GHOSTTY_TEST_SSH_RECORD = Join-Path $scratch 'argv'
    $nativeArgs = @('-o', 'UserKnownHostsFile=C:\known hosts', 'test-host',
        'echo "remote command"', 'path with spaces\', 'a\"b', '|&$', [string][char]0x6d4b, '')
    & $reference @nativeArgs
    $nativeRecord = [IO.File]::ReadAllLines($env:GHOSTTY_TEST_SSH_RECORD)

    foreach ($features in 'title', 'ssh-env', 'ssh-terminfo,path', 'ssh-env,ssh-terminfo,path') {
        & {
            $env:PATH = $originalPath
            $env:GHOSTTY_SHELL_FEATURES = $features
            function ssh { 'original ssh' }
            . $IntegrationPath
            . $IntegrationPath
            if ($GhosttyFeatures -contains 'path') {
                Assert-True ($env:PATH -ceq ($originalPath + ';' + $scratch)) "$features appends the binary directory once"
                $env:PATH = $originalPath + ';' + $scratch.ToUpperInvariant() + '\'
                $equivalent = $env:PATH
                . $IntegrationPath
                Assert-True ($env:PATH -ceq $equivalent) "$features recognizes an equivalent Windows PATH entry"
            } else {
                Assert-True ($env:PATH -ceq $originalPath) "$features leaves PATH alone"
            }

            if ($features -eq 'title') {
                Assert-True ((ssh) -eq 'original ssh') 'disabling both SSH features preserves existing ssh resolution'
                return
            }
            ssh @nativeArgs
            $sshSucceeded = $?
            Assert-True (-not $sshSucceeded) "$features preserves the native SSH failure status"
            Assert-True ($LASTEXITCODE -eq 37) "$features preserves the native SSH exit status"
            $options = @('+ssh')
            if ($GhosttyFeatures -notcontains 'ssh-env') { $options += '--forward-env=false' }
            if ($GhosttyFeatures -notcontains 'ssh-terminfo') { $options += '--terminfo=false' }
            $options += '--'
            $expected = @($options | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) })
            $actual = [IO.File]::ReadAllLines($env:GHOSTTY_TEST_SSH_RECORD)
            Assert-True (($actual -join '|') -ceq (($expected + $nativeRecord) -join '|')) "$features forwards native SSH arguments and the matching feature flags"
            Assert-True (('through stdin' | ssh read-stdin) -ceq 'through stdin') "$features preserves pipeline input"
        }
    }
} finally {
    $env:PATH = $originalPath
    $env:GHOSTTY_BIN_DIR = $originalBin
    $env:GHOSTTY_SHELL_FEATURES = $originalFeatures
    $env:GHOSTTY_TEST_SSH_RECORD = $originalRecord
    $global:LASTEXITCODE = $originalExitCode
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
Write-Output "PowerShell $($PSVersionTable.PSVersion) shell integration checks passed"
