param([Parameter(Mandatory = $true)][string]$ExePath)

# No desktop-global input. All native operations validate the test process and
# window class; controlled raw-mode children report terminal mode 2033 via files.
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class VisibilityTest {
    public static int ProcessId;
    public delegate bool EnumProc(IntPtr h, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder text, int length);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
    [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr h, int command);
    [DllImport("user32.dll", SetLastError=true)] static extern bool PostMessage(IntPtr h, uint message, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int left, top, right, bottom; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT rect);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int width, int height, uint flags);
    static string Class(IntPtr h) {
        var name = new StringBuilder(128); GetClassName(h, name, name.Capacity); return name.ToString();
    }
    public static IntPtr Check(IntPtr h) {
        uint pid;
        if (h == IntPtr.Zero || GetWindowThreadProcessId(h, out pid) == 0 || pid != ProcessId ||
            (Class(h) != "GhosttyWindow" && Class(h) != "GhosttyTerminal"))
            throw new Exception("Refusing a window not owned by this test process");
        return h;
    }
    public static IntPtr[] Find(IntPtr parent, bool visible) {
        var result = new List<IntPtr>();
        string wanted = parent == IntPtr.Zero ? "GhosttyWindow" : "GhosttyTerminal";
        EnumProc callback = delegate(IntPtr h, IntPtr data) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid == ProcessId && Class(h) == wanted && (!visible || IsWindowVisible(h)) &&
                (wanted != "GhosttyTerminal" || GetWindowLongPtr(h, -21) != IntPtr.Zero)) result.Add(h);
            return true;
        };
        if (parent == IntPtr.Zero) EnumWindows(callback, IntPtr.Zero);
        else EnumChildWindows(Check(parent), callback, IntPtr.Zero);
        return result.ToArray();
    }
    public static int VisibleOwnedChrome(IntPtr owner) {
        Check(owner);
        int count = 0;
        EnumProc callback = delegate(IntPtr h, IntPtr data) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid == ProcessId && Class(h) == "GhosttyChrome" &&
                GetWindowLongPtr(h, -8) == owner && IsWindowVisible(h)) count++;
            return true;
        };
        EnumWindows(callback, IntPtr.Zero);
        return count;
    }
    public static bool Visible(IntPtr h) { return IsWindowVisible(Check(h)); }
    public static bool Minimized(IntPtr h) { return IsIconic(Check(h)); }
    public static void Show(IntPtr h, int command) {
        if (!ShowWindowAsync(Check(h), command)) throw new Exception("ShowWindowAsync failed");
    }
    public static void Resize(IntPtr h) {
        RECT rect;
        if (!GetWindowRect(Check(h), out rect) || !SetWindowPos(Check(h), IntPtr.Zero, 0, 0,
            rect.right - rect.left + 30, rect.bottom - rect.top + 20, 0x16))
            throw new Exception("Targeted resize failed");
    }
    public static void Key(IntPtr h, int key) {
        if (Class(Check(h)) != "GhosttyTerminal") throw new Exception("Expected a test-owned surface");
        if (!PostMessage(h, 0x0100, new IntPtr(key), new IntPtr(1)) ||
            !PostMessage(h, 0x0101, new IntPtr(key), new IntPtr(unchecked((int)0xC0000001))))
            throw new Exception("Targeted test binding failed");
    }
}
'@

function Wait-For($condition, $description) {
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (& $condition)) {
        $proc.Refresh()
        if ($proc.HasExited) { throw "Test process exited: $description" }
        if ((Get-Date) -gt $deadline) { throw "Timed out: $description. Diagnostics: $taskDir" }
        Start-Sleep -Milliseconds 50
    }
}
function Assert-True($condition, $description) {
    if (-not $condition) { throw $description }
    Write-Output "PASS=$description"
}

$taskDir = Join-Path $env:TEMP ('ghostty-visibility-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskDir | Out-Null
$linuxDir = & wsl.exe --exec wslpath -u $taskDir
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve visibility test directory in WSL.' }
$childScript = @'
import json, os, re, select, termios, time, tty
root = __ROOT__
fd = 0
original = termios.tcgetattr(fd)
path = os.path.join(root, f'child-{os.getpid()}.json')
report = {'state': None, 'history': [], 'ack': ''}
pending = ''
buffer = b''

def publish():
    with open(path + '.tmp', 'w', encoding='utf-8') as output:
        json.dump(report, output)
    # Antivirus and native Windows readers can briefly lock a file on NTFS.
    for attempt in range(50):
        try:
            os.replace(path + '.tmp', path)
            return
        except PermissionError:
            if attempt == 49:
                raise
            time.sleep(0.01)

try:
    tty.setraw(fd)
    os.write(1, b'\x1b[?2033h')
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline and not os.path.exists(os.path.join(root, 'exit')):
        try:
            with open(os.path.join(root, 'request'), encoding='utf-8') as request:
                token = request.read()
            if token and token != pending:
                pending = token
                os.write(1, b'\x1b[?998n')
        except FileNotFoundError:
            pass
        if not select.select([fd], [], [], 0.05)[0]:
            continue
        data = os.read(fd, 4096)
        if not data:
            break
        buffer += data
        matches = list(re.finditer(rb'\x1b\[\?999;([12])n', buffer))
        for match in matches:
            report['state'] = int(match[1])
            report['history'].append(report['state'])
            report['ack'] = pending
        if matches:
            buffer = buffer[matches[-1].end():]
            publish()
        buffer = buffer[-64:]
except Exception as error:
    report['error'] = repr(error)
    publish()
finally:
    termios.tcsetattr(fd, termios.TCSANOW, original)
'@
$childScript = $childScript.Replace('__ROOT__', ($linuxDir.Trim() | ConvertTo-Json -Compress))
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($childScript))
$bootstrap = "exec(__import__('base64').b64decode('$encoded'))"
$arguments = '--config-default-files=false --auto-update=off --shell-integration=none --resize-overlay=never --window-show-tab-bar=always' +
    ' --quick-terminal-autohide=false --quick-terminal-animation-duration=0.05' +
    ' --keybind=f9=new_tab --keybind=f8=new_split:right --keybind=f7=toggle_split_zoom' +
    ' --keybind=f6=toggle_visibility --keybind=f5=toggle_quick_terminal' +
    ' --command="wsl.exe --exec python3 -c ' + $bootstrap + '"'
$proc = Start-Process -FilePath $ExePath -ArgumentList $arguments -PassThru
$procHandle = $proc.Handle
[VisibilityTest]::ProcessId = $proc.Id
try {
    function Children { @(Get-ChildItem -LiteralPath $taskDir -Filter 'child-*.json' | ForEach-Object { $_.BaseName }) }
    function Read-Report($id) {
        # Let the WSL child atomically replace its report while we read it.
        $file = [IO.File]::Open((Join-Path $taskDir ($id + '.json')), [IO.FileMode]::Open,
            [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader = New-Object IO.StreamReader($file)
        try { $report = $reader.ReadToEnd() | ConvertFrom-Json }
        finally { $reader.Dispose() }
        if ($report.error) { throw "Controlled child $id failed: $($report.error)" }
        return $report
    }
    function Query-States($expected, $description) {
        $token = [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText((Join-Path $taskDir 'request'), $token)
        Wait-For {
            foreach ($id in $expected.Keys) {
                $report = Read-Report $id
                if ($report.ack -ne $token -or $report.state -ne $expected[$id]) { return $false }
            }
            return $true
        } $description
        Write-Output "PASS=$description"
    }
    Wait-For { @([VisibilityTest]::Find([IntPtr]::Zero, $true)).Count -eq 1 -and @(Children).Count -eq 1 } 'initial window and visibility report'
    $window = [VisibilityTest]::Find([IntPtr]::Zero, $true)[0]
    $firstSurface = [VisibilityTest]::Find($window, $true)[0]
    $first = @(Children)[0]
    Query-States @{ $first = 1 } 'initial surface reports potentially visible'

    [VisibilityTest]::Show($window, 0) # SW_HIDE
    Wait-For { -not [VisibilityTest]::Visible($window) } 'top-level hide'
    Query-States @{ $first = 2 } 'hidden parent reports not visible'
    Assert-True ([VisibilityTest]::VisibleOwnedChrome($window) -eq 0) 'hiding the parent leaves no floating tab strip'
    [VisibilityTest]::Resize($window)
    Query-States @{ $first = 2 } 'layout while parent is hidden stays occluded'
    Assert-True ([VisibilityTest]::VisibleOwnedChrome($window) -eq 0) 'hidden-parent layout does not reveal the tab strip'
    [VisibilityTest]::Show($window, 4) # SW_SHOWNOACTIVATE
    Wait-For { [VisibilityTest]::Visible($window) } 'top-level show'
    Query-States @{ $first = 1 } 'showing parent resumes visibility'

    [VisibilityTest]::Key($firstSurface, 0x78) # F9: new tab
    Wait-For { @(Children).Count -eq 2 -and @([VisibilityTest]::Find($window, $true)).Count -eq 1 } 'new tab'
    $second = @(Children | Where-Object { $_ -ne $first })[0]
    $secondSurface = [VisibilityTest]::Find($window, $true)[0]
    Query-States @{ $first = 2; $second = 1 } 'inactive tab remains occluded'
    [VisibilityTest]::Key($secondSurface, 0x77) # F8: split
    Wait-For { @(Children).Count -eq 3 -and @([VisibilityTest]::Find($window, $true)).Count -eq 2 } 'split creation'
    $third = @(Children | Where-Object { $_ -ne $first -and $_ -ne $second })[0]
    $thirdSurface = @([VisibilityTest]::Find($window, $true) | Where-Object { $_ -ne $secondSurface })[0]
    Query-States @{ $first = 2; $second = 1; $third = 1 } 'both active split panes report visible'
    [VisibilityTest]::Key($thirdSurface, 0x76) # F7: zoom
    Wait-For { @([VisibilityTest]::Find($window, $true)).Count -eq 1 } 'split zoom'
    Query-States @{ $first = 2; $second = 2; $third = 1 } 'zoom hides the other split'
    $hiddenHistory = @((Read-Report $second).history).Count
    [VisibilityTest]::Show($window, 0)
    Wait-For { -not [VisibilityTest]::Visible($window) } 'zoomed parent hide'
    Query-States @{ $first = 2; $second = 2; $third = 2 } 'hide occludes every pane'
    Assert-True ([VisibilityTest]::VisibleOwnedChrome($window) -eq 0) 'hiding a zoomed window also hides its tab strip'
    [VisibilityTest]::Show($window, 4)
    Wait-For { [VisibilityTest]::Visible($window) } 'zoomed parent show'
    Query-States @{ $first = 2; $second = 2; $third = 1 } 'show restores only the zoomed pane'
    [VisibilityTest]::Show($window, 7) # SW_SHOWMINNOACTIVE
    Wait-For { [VisibilityTest]::Minimized($window) } 'minimize'
    Query-States @{ $first = 2; $second = 2; $third = 2 } 'minimize occludes every pane'
    Assert-True ([VisibilityTest]::VisibleOwnedChrome($window) -eq 0) 'minimizing the window hides its tab strip'
    [VisibilityTest]::Show($window, 4)
    Wait-For { -not [VisibilityTest]::Minimized($window) } 'restore without activation'
    Query-States @{ $first = 2; $second = 2; $third = 1 } 'restore respects split zoom'
    $history = @((Read-Report $second).history)
    Assert-True (-not ($history | Select-Object -Skip $hiddenHistory | Where-Object { $_ -eq 1 })) 'hidden zoom pane receives no transient visible reports'

    [VisibilityTest]::Key($thirdSurface, 0x76)
    Wait-For { @([VisibilityTest]::Find($window, $true)).Count -eq 2 } 'unzoom'
    Query-States @{ $first = 2; $second = 1; $third = 1 } 'unzoom restores both active panes'
    [VisibilityTest]::Key($thirdSurface, 0x75) # F6: toggle_visibility
    Wait-For { -not [VisibilityTest]::Visible($window) } 'toggle_visibility hide'
    Query-States @{ $first = 2; $second = 2; $third = 2 } 'toggle_visibility publishes hidden state'
    Assert-True ([VisibilityTest]::VisibleOwnedChrome($window) -eq 0) 'toggle_visibility leaves no floating tab strip'
    [VisibilityTest]::Key($thirdSurface, 0x75)
    Wait-For { [VisibilityTest]::Visible($window) } 'toggle_visibility show'
    Query-States @{ $first = 2; $second = 1; $third = 1 } 'toggle_visibility restores active panes only'

    [VisibilityTest]::Key($thirdSurface, 0x74) # F5: quick terminal
    Wait-For { @([VisibilityTest]::Find([IntPtr]::Zero, $true)).Count -eq 2 -and @(Children).Count -eq 4 } 'quick terminal show'
    $quick = @([VisibilityTest]::Find([IntPtr]::Zero, $true) | Where-Object { $_ -ne $window })[0]
    $quickSurface = [VisibilityTest]::Find($quick, $true)[0]
    $fourth = @(Children | Where-Object { $_ -ne $first -and $_ -ne $second -and $_ -ne $third })[0]
    Query-States @{ $fourth = 1 } 'quick terminal reports visible'
    # Wait beyond the configured 50 ms animation before toggling it out.
    Start-Sleep -Milliseconds 150
    [VisibilityTest]::Key($quickSurface, 0x74)
    Wait-For { -not [VisibilityTest]::Visible($quick) } 'quick terminal animation hide'
    Query-States @{ $fourth = 2 } 'animated quick terminal hide publishes not visible'
    [VisibilityTest]::Resize($quick)
    Query-States @{ $fourth = 2 } 'hidden quick terminal layout stays occluded'
} finally {
    [IO.File]::WriteAllText((Join-Path $taskDir 'exit'), 'exit')
    if (-not $proc.WaitForExit(5000)) {
        $cleanup = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\taskkill.exe') `
            -ArgumentList @('/PID', $proc.Id, '/T', '/F') -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput (Join-Path $taskDir 'cleanup.stdout.log') `
            -RedirectStandardError (Join-Path $taskDir 'cleanup.stderr.log')
        $proc.Refresh()
        if ($cleanup.ExitCode -ne 0 -and -not $proc.HasExited) { throw "Could not stop test process $($proc.Id)." }
    }
}
