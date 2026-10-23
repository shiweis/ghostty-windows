param(
    [Parameter(Mandatory)][string]$ExePath,
    [Parameter(Mandatory)][string]$ResourcesPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('opaque','transparent','light','all')][string]$Case='all'
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies @('System.Drawing.Common','System.Drawing.Primitives','System.Private.Windows.Core','System.Runtime.InteropServices','System.ComponentModel.Primitives','System.Collections') -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
public static class TabBarTestNative {
    public static int ProcessId;
    [StructLayout(LayoutKind.Sequential)] public struct Rect {public int Left,Top,Right,Bottom;public int Width {get{return Right-Left;}}}
    delegate bool EnumProc(IntPtr hwnd,IntPtr parameter);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback,IntPtr parameter);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent,EnumProc callback,IntPtr parameter);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd,StringBuilder name,int count);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr hwnd,int index);
    [DllImport("user32.dll",SetLastError=true)] static extern bool PostMessage(IntPtr hwnd,uint message,IntPtr wparam,IntPtr lparam);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr SendMessageTimeout(IntPtr hwnd,uint message,IntPtr wparam,IntPtr lparam,uint flags,uint timeout,out IntPtr result);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd,out Rect rect);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd,out Rect rect);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd,IntPtr dc,uint flags);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd,IntPtr after,int x,int y,int width,int height,uint flags);
    public static IntPtr Check(IntPtr hwnd){uint owner;if(hwnd==IntPtr.Zero||GetWindowThreadProcessId(hwnd,out owner)==0||owner!=(uint)ProcessId)throw new Exception("Refusing a window not owned by the test process");return hwnd;}
    public static IntPtr[] Find(string cls,IntPtr parent,bool visible){
        var found=new List<IntPtr>();
        EnumProc callback=(hwnd,parameter)=>{uint owner;GetWindowThreadProcessId(hwnd,out owner);var name=new StringBuilder(256);GetClassName(hwnd,name,256);bool live=cls!="GhosttyTerminal"||GetWindowLongPtr(hwnd,-21)!=IntPtr.Zero;if(owner==(uint)ProcessId&&live&&name.ToString()==cls&&(!visible||IsWindowVisible(hwnd)))found.Add(hwnd);return true;};
        if(parent==IntPtr.Zero)EnumWindows(callback,IntPtr.Zero);else EnumChildWindows(Check(parent),callback,IntPtr.Zero);
        return found.ToArray();
    }
    public static long Message(IntPtr hwnd,uint message,long wparam,IntPtr lparam){IntPtr result;if(SendMessageTimeout(Check(hwnd),message,new IntPtr(wparam),lparam,3,2000,out result)==IntPtr.Zero)throw new TimeoutException("Owned window did not respond to message "+message);return result.ToInt64();}
    public static void Post(IntPtr hwnd,uint message,long wparam,long lparam){if(!PostMessage(Check(hwnd),message,new IntPtr(wparam),new IntPtr(lparam)))throw new Exception("PostMessage failed");}
    public static void Key(IntPtr hwnd,int key){Post(hwnd,0x100,key,1);Post(hwnd,0x101,key,0xC0000001);}
    public static string Text(IntPtr hwnd){var buffer=Marshal.AllocHGlobal(2048);try{long length=Message(hwnd,0x000D,1024,buffer);return Marshal.PtrToStringUni(buffer,(int)length);}finally{Marshal.FreeHGlobal(buffer);}}
    public static void SetText(IntPtr hwnd,string text){var buffer=Marshal.StringToHGlobalUni(text);try{Message(hwnd,0x000C,0,buffer);}finally{Marshal.FreeHGlobal(buffer);}}
    public static void Position(IntPtr top){SetThreadDpiAwarenessContext(new IntPtr(-4));if(!SetWindowPos(Check(top),IntPtr.Zero,30,30,900,680,0x54))throw new Exception("Positioning owned window failed");}
    static Rect Client(IntPtr top){Rect rect;if(!GetClientRect(Check(top),out rect))throw new Exception("GetClientRect failed");return rect;}
    static long Coordinates(int x,int y){return unchecked((uint)((x&0xffff)|((y&0xffff)<<16)));}
    static void Click(IntPtr top,int x,int y){long point=Coordinates(x,y);Post(top,0x200,0,point);Post(top,0x201,1,point);Post(top,0x202,0,point);}
    public static void TabClick(IntPtr top,int index,int count){var rect=Client(top);double scale=GetDpiForWindow(Check(top))/96.0;double width=(rect.Width-Math.Round(36*scale))/count;Click(top,(int)Math.Round((index+.5)*width),(int)Math.Round(16*scale));}
    public static void PlusClick(IntPtr top){var rect=Client(top);double scale=GetDpiForWindow(Check(top))/96.0;Click(top,rect.Right-(int)Math.Round(18*scale),(int)Math.Round(16*scale));}
    public static void CloseTab(IntPtr top,int index,int count){var rect=Client(top);double scale=GetDpiForWindow(Check(top))/96.0;double width=(rect.Width-Math.Round(36*scale))/count;Click(top,(int)Math.Round((index+1)*width-16*scale),(int)Math.Round(16*scale));}
    public static void RenameTab(IntPtr top,int index,int count){var rect=Client(top);double scale=GetDpiForWindow(Check(top))/96.0;double width=(rect.Width-Math.Round(36*scale))/count;int x=(int)Math.Round((index+.5)*width),y=(int)Math.Round(16*scale);Click(top,x,y);Post(top,0x203,1,Coordinates(x,y));Post(top,0x202,0,Coordinates(x,y));}
    public static void Capture(IntPtr top,string path){
        Rect rect;if(!GetWindowRect(Check(top),out rect))throw new Exception("GetWindowRect failed");
        using(var bitmap=new Bitmap(rect.Width,rect.Bottom-rect.Top)){
            using(var graphics=Graphics.FromImage(bitmap)){var dc=graphics.GetHdc();try{if(!PrintWindow(Check(top),dc,2))throw new Exception("PrintWindow failed");}finally{graphics.ReleaseHdc(dc);}}
            bitmap.Save(path,ImageFormat.Png);
        }
    }
}
'@
New-Item -ItemType Directory -Force $OutputDirectory|Out-Null
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$work=Join-Path $env:TEMP ('ghostty-tab-bar-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work|Out-Null
$fixture=Join-Path $work 'terminal.ps1'
@'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new()
$keys=[Collections.Generic.List[string]]::new()
function Save-State {@{Pid=$PID;Keys=$keys.ToArray()}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $env:GHOSTTY_TAB_TEST_STATE "$PID.json")}
[Console]::Write("`e]2;tab-probe-$PID`a`e[2J`e[Htab-probe-$PID`r`n")
Save-State
while($true){if([Console]::KeyAvailable){$key=[Console]::ReadKey($true);if([int]$key.KeyChar -ge 32){$keys.Add($key.KeyChar.ToString());[Console]::Write("`r`nkeys: "+($keys -join ','));Save-State}};Start-Sleep -Milliseconds 20}
'@|Set-Content -Encoding utf8 $fixture
$record=[ordered]@{Case=$Case;Status='failed';Executable=[IO.Path]::GetFullPath($ExePath);Runs=@();Checks=@();Captures=@();Errors=@()}
$runs=[Collections.Generic.List[object]]::new()
$current=$null
function Check($condition,$name,$metrics){$record.Checks+=@{Name=$name;Passed=[bool]$condition;Metrics=$metrics};if(-not $condition){throw $name}}
function Wait-For($run,[string]$name,[scriptblock]$condition){
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    do{
        if($run.Process.HasExited){throw "$name : process exited with code $($run.Process.ExitCode)"}
        try{if(& $condition){return}}catch{if($_.Exception.InnerException -isnot [TimeoutException]){throw}}
        Start-Sleep -Milliseconds 50
    }while([DateTime]::UtcNow -lt $deadline)
    throw "$name : timed out"
}
function Children($run,[bool]$visible=$true){return @([TabBarTestNative]::Find('GhosttyTerminal',$run.Top,$visible))}
function Shell-Pid($run){$title=[TabBarTestNative]::Text($run.Top);if($title -match '^tab-probe-(\d+)$'){return [int]$Matches[1]};return 0}
function State($run,[int]$pidValue){try{return Get-Content -Raw -LiteralPath (Join-Path $run.State "$pidValue.json")|ConvertFrom-Json}catch{return $null}}
function Screenshot($run,[string]$name){$path=Join-Path $OutputDirectory ($run.Name+'-'+$name+'.png');[TabBarTestNative]::Capture($run.Top,$path);$record.Captures+=@{Name=$name;Mode=$run.Name;Path=$path}}
function Start-Run([double]$opacity,[string]$name){
    $run=@{Name=$name;State=(Join-Path $work $name);Config=(Join-Path $work ($name+'.ghostty'))};New-Item -ItemType Directory $run.State|Out-Null
    $background=if($name -eq 'light'){'#ffffff'}else{'#1e1e2e'}
    $foreground=if($name -eq 'light'){'#1e1e2e'}else{'#ffffff'}
    @(('command = pwsh.exe -NoLogo -NoProfile -File "'+$fixture+'"'),('background-opacity = '+$opacity.ToString([Globalization.CultureInfo]::InvariantCulture)),('background = '+$background),('foreground = '+$foreground),'background-blur = false','font-family = Consolas','font-size = 14','window-show-tab-bar = always','shell-integration = none','confirm-close-surface = false','cursor-style-blink = false','auto-update = off','keybind = f9=new_tab','keybind = f4=next_tab')|Set-Content -Encoding utf8 $run.Config
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=[IO.Path]::GetFullPath($ExePath);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.Environment['GHOSTTY_RESOURCES_DIR']=[IO.Path]::GetFullPath($ResourcesPath);$start.Environment['GHOSTTY_TAB_TEST_STATE']=$run.State
    $start.ArgumentList.Add('--config-default-files=false');$start.ArgumentList.Add('--config-file='+$run.Config)
    $run.Process=[Diagnostics.Process]::Start($start);$runs.Add($run);$run.Stdout=$run.Process.StandardOutput.ReadToEndAsync();$run.Stderr=$run.Process.StandardError.ReadToEndAsync()
    [TabBarTestNative]::ProcessId=$run.Process.Id
    Wait-For $run 'initial native window' {$tops=@([TabBarTestNative]::Find('GhosttyWindow',[IntPtr]::Zero,$true));if($tops.Count -eq 1){$run.Top=$tops[0];return @(Children $run).Count -eq 1};return $false}
    [TabBarTestNative]::Position($run.Top)
    Wait-For $run 'initial terminal fixture' {(Shell-Pid $run) -ne 0}
    return $run
}
try{
    $modes=if($Case -eq 'all'){@(@{Name='opaque';Opacity=1.0},@{Name='transparent';Opacity=0.8},@{Name='light';Opacity=1.0})}elseif($Case -eq 'transparent'){@(@{Name='transparent';Opacity=0.8})}else{@(@{Name=$Case;Opacity=1.0})}
    foreach($mode in $modes){
        $current=Start-Run $mode.Opacity $mode.Name
        $record.Runs+=@{Mode=$mode.Name;Pid=$current.Process.Id;ConfiguredOpacity=$mode.Opacity}
        $first=@(Children $current)[0];$firstPid=Shell-Pid $current
        Screenshot $current 'initial'
        [TabBarTestNative]::Key($first,0x78)
        Wait-For $current 'new-tab binding activates second session' {$visible=@(Children $current);$title=Shell-Pid $current;return @(Children $current $false).Count -eq 2 -and $visible.Count -eq 1 -and $visible[0] -ne $first -and $title -ne 0 -and $title -ne $firstPid}
        $second=@(Children $current)[0];$secondPid=Shell-Pid $current
        Check ($first -ne $second) "$($mode.Name): creating a tab selects a distinct session" @{FirstShell=$firstPid;SecondShell=$secondPid}
        [TabBarTestNative]::Key($second,0x58)
        Wait-For $current 'second session receives x' {$state=State $current $secondPid;return $state -and (@($state.Keys) -join ',') -eq 'x'}
        $firstState=State $current $firstPid
        Check ($firstState -and (@($firstState.Keys) -join ',') -eq '') "$($mode.Name): original session receives no new-tab input" @{FirstShell=$firstPid;SecondShell=$secondPid}
        [TabBarTestNative]::Key($second,0x73)
        Wait-For $current 'next-tab selects first session' {$visible=@(Children $current);return $visible.Count -eq 1 -and $visible[0] -eq $first -and (Shell-Pid $current) -eq $firstPid}
        [TabBarTestNative]::Key($first,0x43)
        Wait-For $current 'first session receives c' {$state=State $current $firstPid;return $state -and (@($state.Keys) -join ',') -eq 'c'}
        Check ((@(State $current $secondPid).Keys -join ',') -eq 'x') "$($mode.Name): switching preserves independent PTY input" @{FirstShell=$firstPid;SecondShell=$secondPid}
        [TabBarTestNative]::Key($first,0x73)
        Wait-For $current 'next-tab returns to second session' {$visible=@(Children $current);return $visible.Count -eq 1 -and $visible[0] -eq $second}
        [TabBarTestNative]::Key($second,0x78)
        Wait-For $current 'third session becomes active' {$visible=@(Children $current);$title=Shell-Pid $current;return @(Children $current $false).Count -eq 3 -and $visible.Count -eq 1 -and $visible[0] -ne $first -and $visible[0] -ne $second -and $title -ne 0 -and $title -ne $firstPid -and $title -ne $secondPid}
        $third=@(Children $current)[0]
        Screenshot $current 'three-tabs'
        [TabBarTestNative]::CloseTab($current.Top,2,3)
        Wait-For $current 'right-side close removes third session' {$visible=@(Children $current);return $visible.Count -eq 1 -and $visible[0] -eq $second -and (Shell-Pid $current) -eq $secondPid}
        [TabBarTestNative]::TabClick($current.Top,2,3)
        Wait-For $current 'closed position cannot select retired session' {$visible=@(Children $current);return $visible.Count -eq 1 -and $visible[0] -eq $second}
        Check (((@(State $current $firstPid).Keys -join ',') -eq 'c') -and ((@(State $current $secondPid).Keys -join ',') -eq 'x')) "$($mode.Name): right close preserves surviving sessions" @{FirstShell=$firstPid;SecondShell=$secondPid}
        [TabBarTestNative]::TabClick($current.Top,0,2)
        Wait-For $current 'fitted first tab selects original session' {(Shell-Pid $current) -eq $firstPid}
        [TabBarTestNative]::PlusClick($current.Top)
        Wait-For $current 'right-edge plus creates a fresh session' {$visible=@(Children $current);$title=Shell-Pid $current;return $visible.Count -eq 1 -and $visible[0] -ne $first -and $visible[0] -ne $second -and $visible[0] -ne $third -and $title -ne 0 -and $title -ne $firstPid -and $title -ne $secondPid}
        Screenshot $current 'right-edge-plus'
        [TabBarTestNative]::RenameTab($current.Top,1,3)
        Wait-For $current 'double click opens title editor' {$editors=@([TabBarTestNative]::Find('Edit',$current.Top,$true));if($editors.Count -eq 1){$script:titleEdit=$editors[0];return $true};return $false}
        [TabBarTestNative]::SetText($titleEdit,'renamed')
        [TabBarTestNative]::Key($titleEdit,0x0D)
        Wait-For $current 'title commit updates selected tab' {[TabBarTestNative]::Text($current.Top) -eq 'renamed' -and @([TabBarTestNative]::Find('Edit',$current.Top,$true)).Count -eq 0}
        [TabBarTestNative]::TabClick($current.Top,0,3)
        Wait-For $current 'other tab keeps original title' {(Shell-Pid $current) -eq $firstPid}
        [TabBarTestNative]::TabClick($current.Top,1,3)
        Wait-For $current 'renamed title survives reselection' {[TabBarTestNative]::Text($current.Top) -eq 'renamed'}
        Check ([TabBarTestNative]::Text($current.Top) -eq 'renamed') "$($mode.Name): edited title persists only on its selected tab" @{Title='renamed';OriginalShell=$firstPid}
        Screenshot $current 'renamed-tab'
        [TabBarTestNative]::Post($current.Top,0x10,0,0)
        if(-not $current.Process.WaitForExit(20000)){$current.Process.Kill($true);$current.Process.WaitForExit()}
    }
    $record.Status='passed'
}catch{
    $record.Errors+=$_.Exception.ToString();$record.Errors+=$_.ScriptStackTrace
    if($current -and -not $current.Process.HasExited -and $current.Top){try{Screenshot $current 'failure'}catch{$record.Errors+='Capture: '+$_.Exception.Message}}
}finally{
    foreach($run in $runs){
        [TabBarTestNative]::ProcessId=$run.Process.Id
        if(-not $run.Process.HasExited){if($run.Top){try{[TabBarTestNative]::Post($run.Top,0x10,0,0)}catch{}};if(-not $run.Process.WaitForExit(5000)){$run.Process.Kill($true);$run.Process.WaitForExit()}}
        [IO.File]::WriteAllText((Join-Path $OutputDirectory ($run.Name+'.stdout.log')),$run.Stdout.GetAwaiter().GetResult())
        [IO.File]::WriteAllText((Join-Path $OutputDirectory ($run.Name+'.stderr.log')),$run.Stderr.GetAwaiter().GetResult())
    }
    $record|ConvertTo-Json -Depth 10|Set-Content (Join-Path $OutputDirectory 'tab-bar-results.json')
    Remove-Item -LiteralPath $work -Recurse -Force
}
Write-Host "Native tab bar: $($record.Status); evidence: $OutputDirectory"
if($record.Status -ne 'passed'){exit 1}
