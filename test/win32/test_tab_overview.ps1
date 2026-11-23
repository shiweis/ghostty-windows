param(
    [Parameter(Mandatory=$true)][string]$ExePath,
    [string]$ScreenshotPath
)

# No SendKeys, SendInput, or foreground/focus requests. Every message target
# is checked against the PID started below, including modal-dialog buttons.
$ErrorActionPreference = 'Stop'
Add-Type -ReferencedAssemblies System.Drawing @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Drawing;
public class OverviewTest {
    public static int ProcessId;
    public delegate bool EnumProc(IntPtr h, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder text, int length);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr h, int id);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
    [DllImport("user32.dll", SetLastError=true)] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int left, top, right, bottom; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT rect);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    public static IntPtr Check(IntPtr h) {
        uint pid;
        if (h == IntPtr.Zero || GetWindowThreadProcessId(h, out pid) == 0 || pid != ProcessId)
            throw new Exception("Refusing a window not owned by this test process");
        return h;
    }
    public static IntPtr[] Find(string name, IntPtr parent, bool visible) {
        var result = new List<IntPtr>();
        EnumProc callback = delegate(IntPtr h, IntPtr data) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            var text = new System.Text.StringBuilder(128); GetClassName(h, text, 128);
            // Win32 retains retired WGL child HWNDs until owner teardown.
            // Cleared userdata distinguishes them from live sessions.
            bool live = name != "GhosttyTerminal" || GetWindowLongPtr(h, -21) != IntPtr.Zero;
            if (pid == ProcessId && live && text.ToString() == name && (!visible || IsWindowVisible(h))) result.Add(h);
            return true;
        };
        if (parent == IntPtr.Zero) EnumWindows(callback, IntPtr.Zero);
        else EnumChildWindows(Check(parent), callback, IntPtr.Zero);
        return result.ToArray();
    }
    public static IntPtr Control(IntPtr h, int id) { return Check(GetDlgItem(Check(h), id)); }
    public static bool Visible(IntPtr h) { return IsWindowVisible(Check(h)); }
    public static bool Enabled(IntPtr h) { return IsWindowEnabled(Check(h)); }
    public static long Message(IntPtr h, uint m, long w, IntPtr l) {
        IntPtr result;
        if (SendMessageTimeout(Check(h), m, new IntPtr(w), l, 3, 2000, out result) == IntPtr.Zero)
            throw new TimeoutException("Test-owned window did not respond to message " + m);
        return result.ToInt64();
    }
    public static void Post(IntPtr h, uint m, long w, long l) {
        if (!PostMessage(Check(h), m, new IntPtr(w), new IntPtr(l))) throw new Exception("PostMessage failed");
    }
    public static void Key(IntPtr h, int key) {
        Post(h, 0x0100, key, 1); Post(h, 0x0101, key, 0xC0000001);
    }
    public static void SetText(IntPtr h, string text) {
        var buffer = Marshal.StringToHGlobalUni(text);
        try { Message(h, 0x000C, 0, buffer); } finally { Marshal.FreeHGlobal(buffer); }
    }
    public static string Text(IntPtr h, int item) {
        var buffer = Marshal.AllocHGlobal(2048);
        try {
            var length = Message(h, item < 0 ? 0x000Du : 0x0189u, item < 0 ? 1024 : item, buffer);
            return length < 0 ? "" : Marshal.PtrToStringUni(buffer, (int)length);
        } finally { Marshal.FreeHGlobal(buffer); }
    }
    public static void Screenshot(IntPtr h, string path) {
        RECT rect;
        if (!GetWindowRect(Check(h), out rect)) throw new Exception("GetWindowRect failed");
        using (var bitmap = new Bitmap(rect.right - rect.left, rect.bottom - rect.top)) {
            using (var graphics = Graphics.FromImage(bitmap)) {
                var dc = graphics.GetHdc();
                try { if (!PrintWindow(Check(h), dc, 2)) throw new Exception("PrintWindow failed"); }
                finally { graphics.ReleaseHdc(dc); }
            }
            bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
    }
}
'@

function Wait-For($condition, $description) {
    $deadline = (Get-Date).AddSeconds(20)
    while ($true) {
        try { $done = & $condition } catch {
            # The existing bounded PTY shutdown may occupy the app thread
            # longer than a single probe. Retry within the overall deadline.
            if ($_.Exception.InnerException -isnot [TimeoutException]) { throw }
            $done = $false
        }
        if ($done) { return }
        if ($proc.HasExited) { throw "Test process exited: $description" }
        if ((Get-Date) -gt $deadline) { throw "Timed out: $description" }
        Start-Sleep -Milliseconds 50
    }
}
function Assert-True($condition, $description) {
    if (-not $condition) { throw $description }
    Write-Output "PASS=$description"
}

$taskDir = Join-Path $env:TEMP ('ghostty-tab-overview-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $taskDir | Out-Null
$escapedDir = $taskDir.Replace("'", "''")
$childScript = @"
`$root = '$escapedDir'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding
`$title = 'Overview-' + `$PID + '-' + [char]0x00C9 + '-' + [char]0x65E5 + [char]0x672C
[Console]::Write([string][char]27 + ']2;' + `$title + [char]7)
[Console]::Out.Flush()
[IO.File]::WriteAllText((Join-Path `$root ('child-' + `$PID)), `$title)
`$deadline = (Get-Date).AddMinutes(3)
while ((Get-Date) -lt `$deadline) {
    if (Test-Path (Join-Path `$root ('exit-' + `$PID))) { break }
    Start-Sleep -Milliseconds 50
}
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
$arguments = '--config-default-files=false --auto-update=off --shell-integration=none' +
    ' --keybind=f9=new_tab --keybind=f10=toggle_tab_overview --keybind=f8=new_split:right' +
    ' --command="powershell.exe -NoLogo -NoProfile -EncodedCommand ' + $encoded + '"'
$proc = Start-Process -FilePath $ExePath -ArgumentList $arguments -PassThru -RedirectStandardError (Join-Path $taskDir 'stderr.log')
$procHandle = $proc.Handle
[OverviewTest]::ProcessId = $proc.Id
try {
    $script:window = [IntPtr]::Zero
    Wait-For {
        $found = [OverviewTest]::Find('GhosttyWindow', [IntPtr]::Zero, $true)
        if ($found.Count -eq 1) { $script:window = $found[0] }
        $script:window -ne [IntPtr]::Zero
    } 'test window startup'
    function Surfaces { [OverviewTest]::Find('GhosttyTerminal', $window, $false) }
    function Active-Surface {
        $script:activeSurface = [IntPtr]::Zero
        Wait-For {
            $found = [OverviewTest]::Find('GhosttyTerminal', $window, $true)
            if ($found.Count -eq 1) { $script:activeSurface = $found[0]; return $true }
            return $false
        } 'one visible unsplit surface after presentation'
        return $script:activeSurface
    }
    function Open-Overview {
        [OverviewTest]::Key((Active-Surface), 0x79) # F10, test-only binding
        Wait-For { @([OverviewTest]::Find('GhosttyTabOverview', [IntPtr]::Zero, $true)).Count -eq 1 } 'overview open'
        $script:overview = [OverviewTest]::Find('GhosttyTabOverview', [IntPtr]::Zero, $true)[0]
        $script:edit = [OverviewTest]::Control($overview, 1001)
        $script:list = [OverviewTest]::Control($overview, 1002)
    }
    function Count { [OverviewTest]::Message($list, 0x018B, 0, [IntPtr]::Zero) }
    function Close-Selected($approve) {
        [OverviewTest]::Post([OverviewTest]::Control($overview, 3), 0x00F5, 0, 0) # BM_CLICK
        Wait-For { @([OverviewTest]::Find('#32770', [IntPtr]::Zero, $true)).Count -eq 1 } 'aggregate close confirmation'
        $dialog = [OverviewTest]::Find('#32770', [IntPtr]::Zero, $true)[0]
        $answer = if ($approve) { 1 } else { 2 }
        [OverviewTest]::Post($dialog, 0x0111, $answer, 0) # owned dialog WM_COMMAND
        Wait-For { @([OverviewTest]::Find('#32770', [IntPtr]::Zero, $true)).Count -eq 0 } 'confirmation dismissed'
    }

    Wait-For { @(Get-ChildItem $taskDir -Filter 'child-*').Count -eq 1 } 'initial controlled child'
    Open-Overview
    Assert-True ((Count) -eq 1) 'single-tab overview works'
    [OverviewTest]::Key($edit, 0x1B)
    Wait-For { -not [OverviewTest]::Visible($overview) } 'Escape closes overview'
    foreach ($expected in @(2, 3)) {
        [OverviewTest]::Key((Active-Surface), 0x78) # F9
        Wait-For { @(Surfaces).Count -eq $expected } "create tab $expected"
        Wait-For { @(Get-ChildItem $taskDir -Filter 'child-*').Count -eq $expected } "controlled child $expected"
    }
    Open-Overview
    Wait-For { [OverviewTest]::Text($list, 1).Contains('Overview-') } 'tab titles parsed'
    Assert-True ((Count) -eq 3) 'overview lists all three tabs'
    $target = [regex]::Match([OverviewTest]::Text($list, 1), 'Overview-\d+').Value
    [OverviewTest]::SetText($edit, $target.ToLowerInvariant())
    Assert-True ((Count) -eq 1) 'case-insensitive title filtering selects one tab'
    [OverviewTest]::Key($edit, 0x0D)
    Wait-For { -not [OverviewTest]::Visible($overview) -and [OverviewTest]::Text($window, -1).Contains($target) } 'Enter switches to filtered tab'
    Open-Overview
    $unicodeQuery = [string][char]0x65E5 + [char]0x672C
    [OverviewTest]::SetText($edit, $unicodeQuery)
    Assert-True ((Count) -eq 3) 'Unicode title filtering keeps matching tabs'
    [OverviewTest]::SetText($edit, 'does-not-match-any-tab')
    Assert-True ((Count) -eq 0 -and -not [OverviewTest]::Enabled([OverviewTest]::Control($overview, 1))) 'empty results disable switching'
    [OverviewTest]::Key($edit, 0x0D)
    Start-Sleep -Milliseconds 100
    Assert-True ([OverviewTest]::Visible($overview)) 'Enter with no results does not switch or dismiss'
    [OverviewTest]::SetText($edit, '')
    if ($ScreenshotPath) { [OverviewTest]::Screenshot($overview, $ScreenshotPath) }
    Close-Selected $false
    Assert-True (@(Surfaces).Count -eq 3) 'cancel preserves running sessions'

    # Split the selected tab, then close it from the overview. Both PTYs
    # must close after one confirmation, not just the focused split.
    [OverviewTest]::Key((Active-Surface), 0x77) # F8
    Wait-For { @(Surfaces).Count -eq 4 } 'create split in selected tab'
    Wait-For { @(Get-ChildItem $taskDir -Filter 'child-*').Count -eq 4 } 'split controlled child'
    $active = [OverviewTest]::Find('GhosttyTerminal', $window, $true)[0]
    [OverviewTest]::Key($active, 0x79)
    Wait-For { [OverviewTest]::Visible($overview) } 'overview opens for split tab'
    Close-Selected $true
    Wait-For { @(Surfaces).Count -eq 2 } 'whole split tab closes'
    Assert-True (@(Surfaces).Count -eq 2) 'one confirmation closes every split in the selected tab'

    # Exit an inactive session through its own control file while overview
    # is open. The live result list must shrink without stale selection.
    Open-Overview
    $selected = [OverviewTest]::Message($list, 0x0188, 0, [IntPtr]::Zero)
    $other = if ($selected -eq 0) { 1 } else { 0 }
    $exitingId = [regex]::Match([OverviewTest]::Text($list, $other), 'Overview-(\d+)').Groups[1].Value
    [IO.File]::WriteAllText((Join-Path $taskDir ('exit-' + $exitingId)), 'exit')
    Wait-For { (Count) -eq 1 } 'overview refresh after inactive child exits'
    Assert-True ((Count) -eq 1) 'process exit refreshes the open overview'
    Close-Selected $true
    Assert-True ($proc.WaitForExit(20000)) 'closing the final tab destroys the overview and exits'
    Assert-True ($proc.ExitCode -eq 0) 'clean app exit'
    $diagnostics = [IO.File]::ReadAllText((Join-Path $taskDir 'stderr.log'))
    Assert-True (-not $diagnostics.Contains('surface thread wedged') -and -not $diagnostics.Contains('panic:')) 'sessions shut down without the thread-leak fallback'
} finally {
    Write-Output "ARTIFACTS=$taskDir"
    $proc.Refresh()
    if (-not $proc.HasExited) {
        & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null
    }
}
