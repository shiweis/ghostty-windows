param(
    [Parameter(Mandatory = $true)][string]$ExePath,
    [string]$BenchPath
)

# A native child replays the same saved Git log through ConPTY in both runs.
# Windows working set includes WGL and other allocations. The optional core
# benchmark reports just the cold pages which Windows successfully discarded.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'owned_windows.ps1')
$repo = (Get-Item -LiteralPath (Join-Path $PSScriptRoot '..\..')).FullName
$taskDir = Join-Path $env:TEMP ('ghostty-compression-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($taskDir)
$revision = & git -c "safe.directory=$($repo.Replace('\','/'))" -C $repo rev-parse HEAD
$records = @(& git -c "safe.directory=$($repo.Replace('\','/'))" -C $repo log --no-merges -n 12000 '--format=%h %s')
if ($LASTEXITCODE -ne 0 -or $records.Count -ne 12000) { throw 'Expected 12,000 commit subjects from the project checkout.' }
$limit = 4194304
$esc = [string][char]27
$utf8 = New-Object Text.UTF8Encoding($false)
$parts = @((New-Object Text.StringBuilder), (New-Object Text.StringBuilder))
for ($i = 0; $i -lt $records.Count; $i++) {
    $subject = ($records[$i] -replace '\p{Cc}', ' ')
    if ($subject.Length -gt 64) { $subject = $subject.Substring(0, 64) }
    $color = if ($i -lt 11750) { '36;80;156' } else { '36;156;80' }
    $part = if ($i -lt 1200) { 0 } else { 1 }
    $null = $parts[$part].Append($esc + '[48;2;' + $color + 'm        ' + $esc + '[0m' +
        ('LOG-{0:D5} ' -f $i) + $subject + [Environment]::NewLine)
}
[IO.File]::WriteAllText((Join-Path $taskDir 'first.vt'), $parts[0].ToString(), $utf8)
[IO.File]::WriteAllText((Join-Path $taskDir 'rest.vt'), $parts[1].ToString(), $utf8)
$corpus = Join-Path $taskDir 'corpus.vt'
[IO.File]::WriteAllText($corpus, ($parts[0].ToString() + $parts[1].ToString()), $utf8)
Write-Output "CORPUS=git $revision, 12000 subjects, 100x30 cells, logical limit $limit bytes, $((Get-Item $corpus).Length) VT bytes"

function Wait-For($condition, $description) {
    $deadline = (Get-Date).AddSeconds(45)
    while (-not (& $condition)) {
        if ($proc.HasExited -or (Get-Date) -gt $deadline) { throw "Failed waiting for $description. Logs in $runDir" }
        Start-Sleep -Milliseconds 50
    }
}
function Sample-Memory($phase) {
    $proc.Refresh()
    Write-Output "MEMORY compression=$enabled phase=$phase working-set=$($proc.WorkingSet64) private=$($proc.PrivateMemorySize64) peak-working-set=$($proc.PeakWorkingSet64)"
}
function Read-History($count) {
    [OwnedTestWindows]::Key($pane, 0x74) # write_scrollback_file:paste
    Wait-For { @(Get-ChildItem $runDir -Filter history.txt -Recurse).Count -eq $count } 'history export'
    $out = Get-ChildItem $runDir -Filter history.txt -Recurse | Sort-Object CreationTime -Descending | Select-Object -First 1
    Wait-For { [IO.File]::ReadAllText($out.FullName).Contains('LOG-') } 'flushed history'
    return [IO.File]::ReadAllText($out.FullName)
}
function Search-Count($key, $pattern) {
    [OwnedTestWindows]::Key($pane, $key)
    Wait-For { [OwnedTestWindows]::ControlText($label) -match $pattern } "native search count $pattern"
}
$firstRetained = $null
foreach ($enabled in @('false','true')) {
    $runDir = Join-Path $taskDir $enabled
    $null = [IO.Directory]::CreateDirectory($runDir)
    $child = @'
$root = '__ROOT__'
$run = '__RUN__'
$esc = [string][char]27
$bel = [string][char]7
function Title($s) { [Console]::Write($esc + ']2;' + $s + $bel) }
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
Title 'ready'
foreach ($part in @('first', 'rest')) {
    while (-not (Test-Path -LiteralPath (Join-Path $run $part))) { Start-Sleep -Milliseconds 50 }
    [Console]::Write([IO.File]::ReadAllText((Join-Path $root ($part + '.vt'))))
    Title $part
}
while (-not (Test-Path -LiteralPath (Join-Path $run 'exit'))) { Start-Sleep -Milliseconds 50 }
'@
    $child = $child.Replace('__ROOT__', $taskDir.Replace("'","''")).Replace('__RUN__', $runDir.Replace("'","''"))
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
    $argsText = '--config-default-files=false --auto-update=off --shell-integration=none --confirm-close-surface=false' +
        ' --background-opacity=1 --window-width=100 --window-height=30 --scrollback-limit=' + $limit +
        ' --scrollback-compression=' + $enabled + ' --keybind=f1=scroll_to_top --keybind=f2=scroll_to_bottom' +
        ' --keybind=f3=start_search --keybind=f4=search:LOG-11500 --keybind=f5=write_scrollback_file:paste' +
        ' --keybind=f6=search:LOG-00000 --command="powershell.exe -NoLogo -NoProfile -EncodedCommand ' + $encoded + '"'
    $oldTmp, $oldTemp = $env:TMP, $env:TEMP
    try {
        $env:TMP = $runDir
        $env:TEMP = $runDir
        $proc = Start-Process $ExePath -ArgumentList $argsText -PassThru -RedirectStandardError (Join-Path $runDir 'stderr.log')
        $handle = $proc.Handle
    } finally { $env:TMP, $env:TEMP = $oldTmp, $oldTemp }
    [OwnedTestWindows]::Pid = $proc.Id
    try {
        Wait-For {
            $found = [OwnedTestWindows]::Find('GhosttyWindow', [IntPtr]::Zero)
            $found.Count -eq 1 -and [OwnedTestWindows]::Title($found[0]) -eq 'ready'
        } 'native child readiness'
        $window = [OwnedTestWindows]::Find('GhosttyWindow', [IntPtr]::Zero)[0]
        $pane = [OwnedTestWindows]::Find('GhosttyTerminal', $window)[0]
        Sample-Memory 'empty'
        foreach ($part in @('first','rest')) {
            [IO.File]::WriteAllText((Join-Path $runDir $part), '')
            Wait-For { [OwnedTestWindows]::Title($window) -eq $part } "$part parsed"
            Sample-Memory "$part-loaded"
            Start-Sleep -Seconds 2
            Sample-Memory "$part-idle"
            if ($part -eq 'first') {
                $early = Read-History 1
                if (-not $early.Contains('LOG-00000 ') -or -not $early.Contains('LOG-01000 ')) { throw 'Initial history missing records.' }
            }
        }
        # The beginning of the retained history is blue. The final 250 lines
        # are green. Sample the eight-space swatch inside the test-owned WGL
        # surface using a window-scoped capture even when another app is in front.
        Wait-For { [OwnedTestWindows]::HasColor($pane, 0x509c24) } 'green live row'
        [OwnedTestWindows]::Key($pane, 0x70)
        Wait-For { [OwnedTestWindows]::HasColor($pane, 0x9c5024) } 'restored blue historical row'
        [OwnedTestWindows]::Key($pane, 0x71)
        Wait-For { [OwnedTestWindows]::HasColor($pane, 0x509c24) } 'return to green live row'
        [OwnedTestWindows]::Key($pane, 0x72)
        Wait-For { [OwnedTestWindows]::Find('GhosttyTerminal', [IntPtr]::Zero).Count -eq 1 } 'search popup'
        $popup = [OwnedTestWindows]::Find('GhosttyTerminal', [IntPtr]::Zero)[0]
        $label = [OwnedTestWindows]::Find('Static', $popup)[0]
        Search-Count 0x73 '/1$'
        Search-Count 0x75 '^0/0$'
        $retained = Read-History 2
        $first = [regex]::Match($retained, 'LOG-(\d+) ')
        if (-not $first.Success -or $first.Groups[1].Value -eq '00000' -or -not $retained.Contains('LOG-11500 ')) {
            throw 'Exported history did not preserve the retained record and prune older data.'
        }
        $index = [int]$first.Groups[1].Value
        if ($null -ne $firstRetained -and $index -ne $firstRetained) { throw 'Compression changed the logical retention limit.' }
        $firstRetained = $index
        Write-Output "PASS=compression=$enabled first-retained=$index, recent/pruned search=1/0, cold/live pixel colors restored"
    } finally {
        [IO.File]::WriteAllText((Join-Path $runDir 'exit'), '')
        if (-not $proc.WaitForExit(5000)) { & "$env:SystemRoot\System32\taskkill.exe" /PID $proc.Id /T /F | Out-Null }
    }
}
if ($BenchPath) {
    $result = Start-Process $BenchPath -ArgumentList ('+scrollback-compression --mode=report --terminal-cols=100 --terminal-rows=30 --max-scrollback=' + $limit + ' --data="' + $corpus + '"') -Wait -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $taskDir 'bench.log')
    $report = [IO.File]::ReadAllText((Join-Path $taskDir 'bench.log'))
    if ($result.ExitCode -ne 0 -or $report -notmatch 'compressed=[1-9]\d* raw=[1-9]\d* encoded=[1-9]\d* ratio=[\d.]+% savings=[1-9]\d*') { throw "Compression report failed: $report" }
    Write-Output $report.Trim()
}
