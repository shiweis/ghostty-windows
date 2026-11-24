# Run in a native console host so the caller controls SSH's three streams.
# Read the original argv because PowerShell's -File binder can reinterpret
# SSH options and the literal '--' separator.
$commandLine = [Environment]::GetCommandLineArgs()
$fileOption = [Array]::IndexOf($commandLine, '-File')
$start = New-Object System.Diagnostics.ProcessStartInfo
$start.FileName = Join-Path $env:GHOSTTY_BIN_DIR 'ghostty.exe'
$start.UseShellExecute = $false
$start.WorkingDirectory = [Environment]::CurrentDirectory

# .NET Framework (Windows PowerShell 5.1) accepts only a single command line.
# Double backslashes before a literal quote or the closing argument quote.
$quoted = for ($i = $fileOption + 2; $i -lt $commandLine.Count; $i++) {
    $arg = [regex]::Replace($commandLine[$i], '(\\*)"', '$1$1\"')
    '"' + [regex]::Replace($arg, '(\\+)$', '$1$1') + '"'
}
$start.Arguments = $quoted -join ' '
try {
    $process = [System.Diagnostics.Process]::Start($start)
    try {
        $process.WaitForExit()
        $status = $process.ExitCode
    } finally {
        $process.Dispose()
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
exit $status
