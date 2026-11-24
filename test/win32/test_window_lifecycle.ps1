param([Parameter(Mandatory = $true)][string]$ExePath)

# All input is posted to HWNDs owned by the process started by this test.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'owned_windows.ps1')

function Wait-For($condition, $description) {
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (& $condition)) {
        if ($proc.HasExited -or (Get-Date) -gt $deadline) { throw "Failed waiting for $description. Logs in $taskDir" }
        Start-Sleep -Milliseconds 50
    }
}
function Windows { [OwnedTestWindows]::Find('GhosttyWindow', [IntPtr]::Zero) }
function Panes($window) { [OwnedTestWindows]::Find('GhosttyTerminal', $window) }
function Dialogs { [OwnedTestWindows]::Find('#32770', [IntPtr]::Zero) }
function Check-Child($window, $count, $expectedStart) {
    Wait-For {
        $script:title = [OwnedTestWindows]::Title($window)
        $script:title -match '^ready-(\d+)' -and -not $seen.ContainsKey($matches[1]) -and @(Get-ChildItem -LiteralPath $taskDir -Filter 'child-*').Count -eq $count -and
            (Test-Path -LiteralPath (Join-Path $taskDir ('child-' + $matches[1])))
    } "ready child $count"
    $childId = [int]([regex]::Match($script:title, '^ready-(\d+)').Groups[1].Value)
    $seen[$childId.ToString()] = $true
    $start = [IO.File]::ReadAllText((Join-Path $taskDir ('child-' + $childId)))
    if ($start -ne $expectedStart) { throw "Child $count started in '$start', expected '$expectedStart'." }
    Write-Host "PASS=child $count started in '$start'"
    return $childId
}
function Confirm-Quit($surface, $answer) {
    [OwnedTestWindows]::Key($surface, 0x75) # F6: quit
    Wait-For { @(Dialogs).Count -eq 1 } 'one quit confirmation for all windows'
    [OwnedTestWindows]::Post(@(Dialogs)[0], 0x111, $answer, 0)
    if ($answer -eq 2) { Wait-For { @(Dialogs).Count -eq 0 } 'quit cancellation' }
}

foreach ($windowInherits in @($true, $false)) {
    $seen = @{}
    $taskDir = Join-Path $env:TEMP ('ghostty-lifecycle-' + [guid]::NewGuid().ToString('N'))
    $base = Join-Path $taskDir 'base'
    $null = New-Item -ItemType Directory -Path $base -Force
    $childScript = @'
$root = '__TASK__'
$initial = [Environment]::CurrentDirectory
$here = Join-Path $root ("report #100% " + $PID)
$null = [IO.Directory]::CreateDirectory($here)
$cwd = [Uri]::EscapeDataString($here.Replace('\', '/')).Replace('%2F', '/').Replace('%3A', ':')
$esc = [string][char]27
$bel = [string][char]7
function Emit($value) { [Console]::Write($esc + ']' + $value + $bel) }
Emit ('7;file://localhost/' + $cwd)
Emit '133;A'
Emit '133;B'
Emit ('2;ready-' + $PID)
[IO.File]::WriteAllText((Join-Path $root ('child-' + $PID)), $initial)
$state = 'prompt'
while (-not (Test-Path -LiteralPath (Join-Path $root 'exit'))) {
    $desired = if (Test-Path -LiteralPath (Join-Path $root ('running-' + $PID))) { 'running' } else { 'prompt' }
    if ($desired -ne $state) {
        if ($desired -eq 'running') { Emit '133;C' } else { Emit '133;A'; Emit '133;B' }
        Emit ('2;' + $desired + '-' + $PID)
        $state = $desired
    }
    Start-Sleep -Milliseconds 50
}
'@
    $childScript = $childScript.Replace('__TASK__', $taskDir.Replace("'", "''"))
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
    $windowFlag = $windowInherits.ToString().ToLowerInvariant()
    $tabFlag = (-not $windowInherits).ToString().ToLowerInvariant()
    $arguments = '--config-default-files=false --auto-update=off --shell-integration=none --confirm-close-surface=true' +
        ' --window-inherit-working-directory=' + $windowFlag + ' --tab-inherit-working-directory=' + $tabFlag +
        ' --split-inherit-working-directory=' + $windowFlag + ' --working-directory="' + $base + '"' +
        ' --keybind=f1=new_window --keybind=f2=new_tab --keybind=f3=new_split:right --keybind=f4=goto_window:next' +
        ' --keybind=f5=goto_window:previous --keybind=f6=quit --keybind=f7=toggle_readonly' +
        ' --command="powershell.exe -NoLogo -NoProfile -EncodedCommand ' + $encoded + '"'
    $proc = Start-Process -FilePath $ExePath -ArgumentList $arguments -PassThru -RedirectStandardError (Join-Path $taskDir 'stderr.log')
    $procHandle = $proc.Handle # Keep the exit status available in Windows PowerShell 5.1.
    [OwnedTestWindows]::Pid = $proc.Id
    try {
        Wait-For { @(Windows).Count -eq 1 } 'initial window'
        $first = @(Windows)[0]
        $one = Check-Child $first 1 $base
        [OwnedTestWindows]::Key(@(Panes $first)[0], 0x71)
        $two = Check-Child $first 2 $(if ($windowInherits) { $base } else { Join-Path $taskDir "report #100% $one" })
        $tab = @(Panes $first)[0]
        [OwnedTestWindows]::Key($tab, 0x72)
        $three = Check-Child $first 3 $(if ($windowInherits) { Join-Path $taskDir "report #100% $two" } else { $base })
        $pane = @(Panes $first | Where-Object { $_ -ne $tab })[0]
        [OwnedTestWindows]::Key($pane, 0x70)
        Wait-For { @(Windows).Count -eq 2 } 'second window'
        $second = @(Windows | Where-Object { $_ -ne $first })[0]
        $four = Check-Child $second 4 $(if ($windowInherits) { Join-Path $taskDir "report #100% $three" } else { $base })
        $secondPane = @(Panes $second)[0]

        [OwnedTestWindows]::Key($secondPane, 0x73)
        Wait-For { [OwnedTestWindows]::Focus($first) -eq $pane } 'next window wrapping to its selected tab and split'
        [OwnedTestWindows]::Key($pane, 0x74)
        Wait-For { [OwnedTestWindows]::Focus($second) -eq $secondPane } 'previous window wrapping to its selected pane'
        Write-Output 'PASS=both directions preserve the selected tab and split on wraparound'

        $running = Join-Path $taskDir "running-$three"
        [IO.File]::WriteAllText($running, '')
        Wait-For { [OwnedTestWindows]::Title($first) -like "running-$three*" } 'background split reporting command execution'
        Confirm-Quit $secondPane 2
        if (@(Windows).Count -ne 2 -or @(Get-Process -Id @($one,$two,$three,$four)).Count -ne 4) { throw 'Cancel lost a live session' }
        Write-Output 'PASS=canceling quit for a running background split preserves every child'
        Remove-Item -LiteralPath $running
        Wait-For { [OwnedTestWindows]::Title($first) -like "prompt-$three*" } 'background split returning to its prompt'
        [OwnedTestWindows]::Key($secondPane, 0x76)
        Confirm-Quit $secondPane $(if ($windowInherits) { 2 } else { 1 })
        if ($windowInherits) {
            [OwnedTestWindows]::Key($secondPane, 0x76)
            [OwnedTestWindows]::Key($secondPane, 0x75)
        }
        if (-not $proc.WaitForExit(20000)) { throw "Quit timed out. Logs in $taskDir" }
        if ($proc.ExitCode -ne 0) { throw "Quit exited with code $($proc.ExitCode). Logs in $taskDir" }
        Write-Output 'PASS=read-only surface requires confirmation and clean prompts allow quitting'
    } finally {
        [IO.File]::WriteAllText((Join-Path $taskDir 'exit'), '')
        if (-not $proc.WaitForExit(5000)) {
            & "$env:SystemRoot\System32\taskkill.exe" /PID $proc.Id /T /F | Out-Null
        }
    }
}
