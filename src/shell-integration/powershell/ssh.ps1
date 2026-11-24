# PowerShell does not wait for a GUI-subsystem executable in an
# interactive invocation. A console host gives both interactive SSH
# and pipelines normal native command semantics.
$engine = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' }
$engine = Join-Path $PSHOME $engine
$launcher = Join-Path $PSScriptRoot 'ghostty-ssh.ps1'
$hostArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $launcher)
$flags = @('+ssh')
if ($GhosttyFeatures -notcontains 'ssh-env') { $flags += '--forward-env=false' }
if ($GhosttyFeatures -notcontains 'ssh-terminfo') { $flags += '--terminfo=false' }
$flags += '--'
if ($MyInvocation.ExpectingInput) { $input | & $engine @hostArgs @flags @args }
else { & $engine @hostArgs @flags @args }
exit $LASTEXITCODE
