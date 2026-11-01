param(
    [Parameter(Mandatory)][string]$ExePath,
    [Parameter(Mandatory)][string]$ResourcesPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('opaque','transparent','light','close','all')][string]$Case='all'
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$nativeReferences=@('System.Drawing.Common','System.Drawing.Primitives','System.Private.Windows.Core','System.Runtime.InteropServices','System.ComponentModel.Primitives','System.Collections')
if(Test-Path (Join-Path $PSHOME 'System.Private.Windows.GdiPlus.dll')){$nativeReferences+='System.Private.Windows.GdiPlus'}
Add-Type -ReferencedAssemblies $nativeReferences -TypeDefinition @'
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
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll",SetLastError=true)] static extern bool PostMessage(IntPtr hwnd,uint message,IntPtr wparam,IntPtr lparam);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr SendMessageTimeout(IntPtr hwnd,uint message,IntPtr wparam,IntPtr lparam,uint flags,uint timeout,out IntPtr result);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd,out Rect rect);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd,out Rect rect);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd,IntPtr dc,uint flags);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd,IntPtr after,int x,int y,int width,int height,uint flags);
    [DllImport("user32.dll")] static extern bool RedrawWindow(IntPtr hwnd,IntPtr updateRect,IntPtr updateRegion,uint flags);
    public static IntPtr Check(IntPtr hwnd){uint owner;if(hwnd==IntPtr.Zero||GetWindowThreadProcessId(hwnd,out owner)==0||owner!=(uint)ProcessId)throw new Exception("Refusing a window not owned by the test process");return hwnd;}
    public static IntPtr[] Find(string cls,IntPtr parent,bool visible){
        var found=new List<IntPtr>();
        EnumProc callback=(hwnd,parameter)=>{uint owner;GetWindowThreadProcessId(hwnd,out owner);var name=new StringBuilder(256);GetClassName(hwnd,name,256);bool live=cls!="GhosttyTerminal"||GetWindowLongPtr(hwnd,-21)!=IntPtr.Zero;if(owner==(uint)ProcessId&&live&&name.ToString()==cls&&(!visible||IsWindowVisible(hwnd)))found.Add(hwnd);return true;};
        if(parent==IntPtr.Zero)EnumWindows(callback,IntPtr.Zero);else EnumChildWindows(Check(parent),callback,IntPtr.Zero);
        return found.ToArray();
    }
    public static long Message(IntPtr hwnd,uint message,long wparam,IntPtr lparam){IntPtr result;if(SendMessageTimeout(Check(hwnd),message,new IntPtr(wparam),lparam,3,2000,out result)==IntPtr.Zero)throw new TimeoutException("Owned window did not respond to message "+message);return result.ToInt64();}
    public static void Post(IntPtr hwnd,uint message,long wparam,long lparam){if(!PostMessage(Check(hwnd),message,new IntPtr(wparam),new IntPtr(lparam)))throw new Exception("PostMessage failed");}
    public static bool DialogCommand(IntPtr hwnd,int id){if(!IsWindow(hwnd))return false;uint owner;if(GetWindowThreadProcessId(hwnd,out owner)==0||owner!=(uint)ProcessId)return false;return PostMessage(hwnd,0x0111,new IntPtr(id),IntPtr.Zero);}
    public static void Key(IntPtr hwnd,int key){Post(hwnd,0x100,key,1);Post(hwnd,0x101,key,0xC0000001);}
    public static string Text(IntPtr hwnd){var buffer=Marshal.AllocHGlobal(2048);try{long length=Message(hwnd,0x000D,1024,buffer);return Marshal.PtrToStringUni(buffer,(int)length);}finally{Marshal.FreeHGlobal(buffer);}}
    public static void SetText(IntPtr hwnd,string text){var buffer=Marshal.StringToHGlobalUni(text);try{Message(hwnd,0x000C,0,buffer);}finally{Marshal.FreeHGlobal(buffer);}}
    public static void Position(IntPtr top){SetThreadDpiAwarenessContext(new IntPtr(-4));if(!SetWindowPos(Check(top),IntPtr.Zero,30,30,900,680,0x54))throw new Exception("Positioning owned window failed");}
    public static void Paint(IntPtr top){if(!RedrawWindow(Check(top),IntPtr.Zero,IntPtr.Zero,0x0101))throw new Exception("RedrawWindow failed");}
    static Rect Client(IntPtr top){Rect rect;if(!GetClientRect(Check(top),out rect))throw new Exception("GetClientRect failed");return rect;}
    static long Coordinates(int x,int y){return unchecked((uint)((x&0xffff)|((y&0xffff)<<16)));}
    static void Click(IntPtr top,int x,int y){long point=Coordinates(x,y);Post(top,0x200,0,point);Post(top,0x201,1,point);Post(top,0x202,0,point);}
    static int TabX(IntPtr top,int index,int count){var rect=Client(top);double scale=GetDpiForWindow(Check(top))/96.0;double width=(rect.Width-Math.Round(36*scale))/count;return (int)Math.Round((index+.5)*width);}
    static int TabY(IntPtr top){return (int)Math.Round(16*GetDpiForWindow(Check(top))/96.0);}
    public static void TabClick(IntPtr top,int index,int count){Click(top,TabX(top,index,count),TabY(top));}
    public static void RenameTab(IntPtr top,int index,int count){int x=TabX(top,index,count),y=TabY(top);long point=Coordinates(x,y);Click(top,x,y);Post(top,0x203,1,point);Post(top,0x202,0,point);}
    public static void PlusClick(IntPtr top){var rect=Client(top);double scale=GetDpiForWindow(Check(top))/96.0;Click(top,rect.Right-(int)Math.Round(18*scale),TabY(top));}
    public static void CloseTab(IntPtr top,int index,int count){var rect=Client(top);double scale=GetDpiForWindow(Check(top))/96.0;double width=(rect.Width-Math.Round(36*scale))/count;Click(top,(int)Math.Round((index+1)*width-16*scale),TabY(top));}
    public static void MiddleTab(IntPtr top,int index,int count){Post(top,0x207,0,Coordinates(TabX(top,index,count),TabY(top)));}
    public static void MiddleSequence(IntPtr top,int index,int count){long point=Coordinates(TabX(top,index,count),TabY(top));Post(top,0x207,0,point);Post(top,0x208,0,point);Post(top,0x209,0,point);Post(top,0x208,0,point);}
    public static void MiddlePlus(IntPtr top){var rect=Client(top);double scale=GetDpiForWindow(Check(top))/96.0;Post(top,0x207,0,Coordinates(rect.Right-(int)Math.Round(18*scale),TabY(top)));}
    public static void MiddleNegative(IntPtr top){Post(top,0x207,0,Coordinates(-1,TabY(top)));}
    public static void MiddleBelow(IntPtr top){double scale=GetDpiForWindow(Check(top))/96.0;Post(top,0x207,0,Coordinates(100,(int)Math.Ceiling(32*scale)));}
    public static void MiddleCloseRegion(IntPtr top,int index,int count){var rect=Client(top);double scale=GetDpiForWindow(Check(top))/96.0;double width=(rect.Width-Math.Round(36*scale))/count;Post(top,0x207,0,Coordinates((int)Math.Round((index+1)*width-16*scale),TabY(top)));}
    public static void TerminalMiddle(IntPtr child){long point=Coordinates(2,2);Post(child,0x207,0x10,point);Post(child,0x208,0,point);}
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
# Stage a matching portable payload locally even when this script is called
# from a WSL checkout. UNC execution can trigger Windows security prompts.
$stagedExecutable=Join-Path $work 'ghostty-tab-bar-test.exe'
$stagedShare=Join-Path $work 'share'
try{
    $binaryDirectory=Split-Path -Parent ([IO.Path]::GetFullPath($ExePath))
    Copy-Item -LiteralPath $ExePath -Destination $stagedExecutable
    foreach($runtime in @('conpty.dll','OpenConsole.exe')){
        Copy-Item -LiteralPath (Join-Path $binaryDirectory $runtime) -Destination $work
    }
    # Compiled terminfo contains Unix symlinks that cannot be followed from
    # Windows. Match portable packaging and copy only the plain-text sentinel.
    foreach($relativePath in @('ghostty\themes','ghostty\shell-integration','terminfo\ghostty.terminfo','licenses\conpty\LICENSE.txt')){
        $destination=Join-Path $stagedShare $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force|Out-Null
        Copy-Item -LiteralPath (Join-Path $ResourcesPath $relativePath) -Destination $destination -Recurse
    }
}catch{
    Remove-Item -LiteralPath $work -Recurse -Force
    throw
}
$fixture=Join-Path $work 'terminal.ps1'
@'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new()
$keys=[Collections.Generic.List[string]]::new()
function Save-State {@{Pid=$PID;Keys=$keys.ToArray()}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $env:GHOSTTY_TAB_TEST_STATE "$PID.json")}
$titleSuffix=''
if(Test-Path (Join-Path $env:GHOSTTY_TAB_TEST_STATE "prompt-$PID")){$titleSuffix='-prompt'}
New-Item -ItemType File -Force (Join-Path $env:GHOSTTY_TAB_TEST_STATE "live-$PID")|Out-Null
[Console]::Write("`e]2;tab-probe-$PID$titleSuffix`a`e[2J`e[Htab-probe-$PID`r`n")
Save-State
while($true){
    if(Test-Path (Join-Path $env:GHOSTTY_TAB_TEST_STATE "exit-$PID")){Remove-Item (Join-Path $env:GHOSTTY_TAB_TEST_STATE "live-$PID") -Force -ErrorAction SilentlyContinue;exit 0}
    if(Test-Path (Join-Path $env:GHOSTTY_TAB_TEST_STATE "prompt-$PID")){
        Remove-Item (Join-Path $env:GHOSTTY_TAB_TEST_STATE "prompt-$PID") -Force
        [Console]::Write("`e]133;A`a");[Console]::Write('prompt$ ');[Console]::Write("`e]133;B`a")
        [Console]::Write("`e]2;tab-probe-$PID-prompt`a")
    }
    if(Test-Path (Join-Path $env:GHOSTTY_TAB_TEST_STATE "mouse-$PID")){
        Remove-Item (Join-Path $env:GHOSTTY_TAB_TEST_STATE "mouse-$PID") -Force
        [Console]::Write("`e[?1000h`e[?1006h")
        [Console]::Write("`e]2;tab-probe-$PID-mouse`a")
        New-Item -ItemType File -Force (Join-Path $env:GHOSTTY_TAB_TEST_STATE "mouse-ready-$PID")|Out-Null
    }
    if([Console]::KeyAvailable){$key=[Console]::ReadKey($true);if([int]$key.KeyChar -ge 32){$keys.Add($key.KeyChar.ToString());[Console]::Write("`r`nkeys: "+($keys -join ','));Save-State}}
    Start-Sleep -Milliseconds 20
}
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
function Wait-Until([string]$name,[scriptblock]$condition){
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    do{if(& $condition){return};Start-Sleep -Milliseconds 50}while([DateTime]::UtcNow -lt $deadline)
    throw "$name : timed out"
}
function Children($run,[bool]$visible=$true){return @([TabBarTestNative]::Find('GhosttyTerminal',$run.Top,$visible))}
function Shell-Pid($run){$title=[TabBarTestNative]::Text($run.Top);if($title -match '^tab-probe-(\d+)(?:-prompt|-mouse)?$'){return [int]$Matches[1]};return 0}
function State($run,[int]$pidValue){try{return Get-Content -Raw -LiteralPath (Join-Path $run.State "$pidValue.json")|ConvertFrom-Json}catch{return $null}}
function Screenshot($run,[string]$name){$path=Join-Path $OutputDirectory ($run.Name+'-'+$name+'.png');[TabBarTestNative]::Capture($run.Top,$path);$record.Captures+=@{Name=$name;Mode=$run.Name;Path=$path}}
function Request-Exit($run,[int]$pidValue){[IO.File]::WriteAllText((Join-Path $run.State "exit-$pidValue"),'exit')}
function Request-Prompt($run,[int]$pidValue){[IO.File]::WriteAllText((Join-Path $run.State "prompt-$pidValue"),'prompt')}
function Request-MouseReporting($run,[int]$pidValue){[IO.File]::WriteAllText((Join-Path $run.State "mouse-$pidValue"),'mouse')}
function Dialogs($run){[TabBarTestNative]::ProcessId=$run.Process.Id;return @([TabBarTestNative]::Find('#32770',[IntPtr]::Zero,$true))}
function Answer-Dialog($run,[int]$answer){
    $dialogs=@(Dialogs $run)
    if($dialogs.Count -ne 1){throw "Expected exactly one owned confirmation dialog; found $($dialogs.Count)"}
    [void][TabBarTestNative]::DialogCommand($dialogs[0],$answer)
}
function Capture-Dialog($run,[string]$name){
    $dialogs=@(Dialogs $run)
    if($dialogs.Count -ne 1){throw "Cannot capture confirmation: expected one owned dialog, found $($dialogs.Count)"}
    $path=Join-Path $OutputDirectory ($run.Name+'-'+$name+'.png')
    [TabBarTestNative]::Capture($dialogs[0],$path)
    $record.Captures+=@{Name=$name;Mode=$run.Name;Path=$path}
}
function Start-Run([double]$opacity,[string]$name,[bool]$confirm=$false,[string]$showTabBar='always'){
    $run=@{Name=$name;State=(Join-Path $work $name);Config=(Join-Path $work ($name+'.ghostty'))};New-Item -ItemType Directory $run.State|Out-Null
    $background=if($name -eq 'light'){'#ffffff'}else{'#1e1e2e'}
    $foreground=if($name -eq 'light'){'#1e1e2e'}else{'#ffffff'}
    $configLines=@(('command = pwsh.exe -NoLogo -NoProfile -File "'+$fixture+'"'),('background-opacity = '+$opacity.ToString([Globalization.CultureInfo]::InvariantCulture)),('background = '+$background),('foreground = '+$foreground),'background-blur = false','font-family = Consolas','font-size = 14',('window-show-tab-bar = '+$showTabBar),'shell-integration = none',('confirm-close-surface = '+$confirm.ToString().ToLowerInvariant()),'cursor-style-blink = false','auto-update = off','keybind = f9=new_tab','keybind = f4=next_tab')
    if($name.StartsWith('close-')){$configLines+='keybind = f8=new_split:right'}
    $configLines|Set-Content -Encoding utf8 $run.Config
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$stagedExecutable;$start.WorkingDirectory=$work;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.Environment['GHOSTTY_RESOURCES_DIR']=Join-Path $stagedShare 'ghostty';$start.Environment['GHOSTTY_TAB_TEST_STATE']=$run.State
    $start.ArgumentList.Add('--config-default-files=false');$start.ArgumentList.Add('--config-file='+$run.Config)
    $run.Process=[Diagnostics.Process]::Start($start);$runs.Add($run);$run.Stdout=$run.Process.StandardOutput.ReadToEndAsync();$run.Stderr=$run.Process.StandardError.ReadToEndAsync();$script:current=$run;$record.Runs+=@{Mode=$name;Pid=$run.Process.Id;ConfiguredOpacity=$opacity;ConfirmCloseSurface=$confirm;TabBar=$showTabBar}
    [TabBarTestNative]::ProcessId=$run.Process.Id
    Wait-For $run 'initial native window' {$tops=@([TabBarTestNative]::Find('GhosttyWindow',[IntPtr]::Zero,$true));if($tops.Count -eq 1){$run.Top=$tops[0];return @(Children $run).Count -eq 1};return $false}
    [TabBarTestNative]::Position($run.Top)
    Wait-For $run 'initial terminal fixture' {(Shell-Pid $run) -ne 0}
    [TabBarTestNative]::Paint($run.Top)
    return $run
}
function Child-Pids($run){return @((Get-ChildItem -LiteralPath $run.State -Filter 'live-*' -ErrorAction SilentlyContinue)|ForEach-Object{[int]$_.Name.Substring(5)})}
function Child-ProcessAlive([int]$pidValue){return [bool](Get-Process -Id $pidValue -ErrorAction SilentlyContinue)}
function Select-Pid($run,[int]$pidValue){
    for($attempt=0;$attempt -lt 4 -and (Shell-Pid $run) -ne $pidValue;$attempt++){
        $prior=Shell-Pid $run
        [TabBarTestNative]::Key((Children $run)[0],0x73)
        Wait-For $run "select tab for child $pidValue" {$next=Shell-Pid $run;return $next -ne 0 -and $next -ne $prior}
    }
    if((Shell-Pid $run) -ne $pidValue){throw "Could not select tab for child $pidValue; active child is $(Shell-Pid $run)"}
}
function Add-Tabs($run,[int]$count){
    $ids=[Collections.Generic.List[int]]::new()
    $ids.Add((Shell-Pid $run))
    while($ids.Count -lt $count){
        $prior=Shell-Pid $run
        [TabBarTestNative]::Key((Children $run)[0],0x78)
        Wait-For $run "new controlled tab $($ids.Count+1)" {@(Children $run $false).Count -eq $ids.Count+1 -and (Shell-Pid $run) -ne 0 -and (Shell-Pid $run) -ne $prior}
        $ids.Add((Shell-Pid $run))
    }
    [TabBarTestNative]::Paint($run.Top)
    return $ids.ToArray()
}
function Close-ByGesture($run,[string]$gesture,[int]$index,[int]$count){
    if($gesture -eq 'middle'){[TabBarTestNative]::MiddleTab($run.Top,$index,$count)}
    elseif($gesture -eq 'x'){[TabBarTestNative]::CloseTab($run.Top,$index,$count)}
    else{throw "Unknown close gesture $gesture"}
}
function Stop-RunCleanly($run){
    foreach($pidValue in @(Child-Pids $run)){Request-Exit $run $pidValue}
    $run.Process.Refresh()
    if(-not $run.Process.HasExited -and -not $run.Process.WaitForExit(20000)){
        foreach($dialog in @(Dialogs $run)){[TabBarTestNative]::Post($dialog,0x0111,1,0)}
        if(-not $run.Process.WaitForExit(5000)){throw "$($run.Name): controlled children did not permit clean app exit"}
    }
}
function Run-MiddleActive{
    $run=Start-Run 1.0 'close-middle-active' $false
    $ids=@(Add-Tabs $run 2);$prior=$ids[0];$target=$ids[1]
    Close-ByGesture $run 'middle' 1 2
    Wait-For $run 'middle press closes active non-final tab and selects predecessor' {@(Children $run $false).Count -eq 1 -and (Shell-Pid $run) -eq $prior -and -not (Child-ProcessAlive $target)}
    Check ((Children $run).Count -eq 1 -and (Shell-Pid $run) -eq $prior) 'close: active middle-close selects preceding tab' @{Previous=$prior;Closed=$target}
    Stop-RunCleanly $run
    Check ($run.Process.ExitCode -eq 0) 'close: active-tab fixture exits cleanly' @{ExitCode=$run.Process.ExitCode}
}
function Run-MiddleActiveNonRightmost{
    $run=Start-Run 1.0 'close-middle-active-middle' $false
    $ids=@(Add-Tabs $run 3);$target=$ids[1];$successor=$ids[2]
    Select-Pid $run $target
    Close-ByGesture $run 'middle' 1 3
    Wait-For $run 'middle press closes active middle tab and selects successor' {@(Children $run $false).Count -eq 2 -and (Shell-Pid $run) -eq $successor -and -not (Child-ProcessAlive $target)}
    Check ((Children $run).Count -eq 1 -and (Shell-Pid $run) -eq $successor) 'close: active middle-tab close selects its successor' @{Closed=$target;Successor=$successor}
    Stop-RunCleanly $run
    Check ($run.Process.ExitCode -eq 0) 'close: active middle-tab fixture exits cleanly' @{ExitCode=$run.Process.ExitCode}
}
function Run-InactiveIdentity([string]$gesture,[int]$index){
    $run=Start-Run 1.0 "close-$gesture-inactive-$index" $false
    $ids=@(Add-Tabs $run 3);$active=$ids[1];$target=$ids[$index]
    Select-Pid $run $active
    $activeHwnd=@(Children $run)[0]
    Close-ByGesture $run $gesture $index 3
    Wait-For $run "$gesture closes only inactive tab $index" {@(Children $run $false).Count -eq 2 -and -not (Child-ProcessAlive $target)}
    Check ((Shell-Pid $run) -eq $active -and @(Children $run)[0] -eq $activeHwnd) "close: $gesture inactive close preserves active HWND/PID" @{Target=$target;Active=$active}
    Check ((Dialogs $run).Count -eq 0) "close: $gesture with confirmation disabled closes without a dialog" @{Target=$target;Active=$active}
    [TabBarTestNative]::Key(@(Children $run)[0],0x58)
    Wait-For $run "$gesture routes key to active survivor" {$s=State $run $active;return $s -and (@($s.Keys)-join ',') -eq 'x'}
    $other=@($ids|Where-Object{$_ -ne $target -and $_ -ne $active})[0]
    Check ((@(State $run $other).Keys -join ',') -eq '') "close: $gesture leaves other survivor input unchanged" @{Active=$active;Other=$other}
    Stop-RunCleanly $run
}
function Run-Confirm([string]$gesture,[bool]$approve,[bool]$promptOnly=$false){
    $run=Start-Run 1.0 "close-confirm-$gesture-$approve-$promptOnly" $true
    $ids=@(Add-Tabs $run 2);$active=$ids[1];$target=$ids[0]
    Select-Pid $run $target
    if($promptOnly){Request-Prompt $run $target;Wait-For $run 'prompt title acknowledgment' {[TabBarTestNative]::Text($run.Top) -eq "tab-probe-$target-prompt"}}
    else{[TabBarTestNative]::Key(@(Children $run)[0],0x58);Wait-For $run 'target child records running input' {$s=State $run $target;return $s -and (@($s.Keys)-join ',') -eq 'x'}}
    Select-Pid $run $active
    $activeHwnd=@(Children $run)[0]
    Close-ByGesture $run $gesture 0 2
    if($promptOnly){
        Wait-For $run "$gesture idle prompt closes without confirmation" {@(Dialogs $run).Count -eq 0 -and @(Children $run $false).Count -eq 1}
        Check ((-not (Child-ProcessAlive $target)) -and (Shell-Pid $run) -eq $active) "close: $gesture prompt-only tab closes without dialog" @{Target=$target}
    }else{
        Wait-For $run "$gesture opens one close confirmation" {@(Dialogs $run).Count -eq 1}
        Check (@(Dialogs $run).Count -eq 1) "close: $gesture running child opens one dialog" @{Target=$target}
        Capture-Dialog $run "$gesture-confirm-$approve"
        Answer-Dialog $run $(if($approve){1}else{2})
        Wait-For $run "$gesture confirmation answer completes" {@(Dialogs $run).Count -eq 0}
        if($approve){Wait-For $run "$gesture OK closes targeted tab only" {@(Children $run $false).Count -eq 1 -and -not (Child-ProcessAlive $target) -and (Shell-Pid $run) -eq $active -and @(Children $run)[0] -eq $activeHwnd}}
        else{
            Wait-For $run "$gesture Cancel retains both tabs" {@(Children $run $false).Count -eq 2 -and (Shell-Pid $run) -eq $active}
            Check ((Child-ProcessAlive $target) -and (Shell-Pid $run) -eq $active -and @(Children $run)[0] -eq $activeHwnd) "close: $gesture Cancel preserves target and active identity" @{Target=$target;Active=$active}
        }
    }
    Stop-RunCleanly $run
}
function Run-SplitProtection([string]$gesture,[bool]$approve){
    $run=Start-Run 1.0 "close-split-$gesture-$approve" $true
    $original=Shell-Pid $run
    [TabBarTestNative]::Key((Children $run)[0],0x77)
    Wait-For $run 'split fixture creates second controlled child' {@(Children $run $false).Count -eq 2 -and @(Child-Pids $run).Count -eq 2}
    $splitPids=@(Child-Pids $run);$target=@($splitPids|Where-Object{$_ -ne $original})[0];$other=$original
    Wait-For $run 'new split becomes the focused representative' {(Shell-Pid $run) -eq $target}
    Request-Prompt $run $target
    Wait-For $run 'focused split emits prompt title acknowledgment' {[TabBarTestNative]::Text($run.Top) -eq "tab-probe-$target-prompt"}
    [TabBarTestNative]::Key((Children $run)[0],0x78)
    Wait-For $run 'unrelated tab becomes active' {@(Children $run $false).Count -eq 3 -and @(Child-Pids $run).Count -eq 3 -and (Shell-Pid $run) -ne $target}
    [TabBarTestNative]::Paint($run.Top)
    $survivor=Shell-Pid $run;$survivorHwnd=@(Children $run)[0];$splitHwnds=@(Children $run $false)
    Close-ByGesture $run $gesture 0 2
    Wait-For $run "$gesture split close prompts for non-focused running split" {@(Dialogs $run).Count -eq 1}
    Capture-Dialog $run "$gesture-split-$approve"
    Answer-Dialog $run $(if($approve){1}else{2})
    Wait-For $run "$gesture split confirmation is dismissed" {@(Dialogs $run).Count -eq 0}
    if($approve){
        Wait-For $run "$gesture OK closes both target splits only" {@(Children $run $false).Count -eq 1 -and (Shell-Pid $run) -eq $survivor -and -not (Child-ProcessAlive $target) -and -not (Child-ProcessAlive $other) -and @(Children $run)[0] -eq $survivorHwnd}
    }else{
        Wait-For $run "$gesture Cancel retains unrelated tab and both splits" {@(Children $run $false).Count -eq 3 -and (Shell-Pid $run) -eq $survivor}
        Check ((Child-ProcessAlive $target) -and (Child-ProcessAlive $other) -and (Child-ProcessAlive $survivor) -and @($splitHwnds|Where-Object{$_ -notin @(Children $run $false)}).Count -eq 0) "close: $gesture split Cancel preserves both split HWNDs and active identity" @{Representative=$target;OtherSplit=$other;Survivor=$survivor}
    }
    Stop-RunCleanly $run
}
function Run-ModalExit([bool]$allChildren){
    $run=Start-Run 1.0 "close-modal-exit-$allChildren" $true
    $ids=@(Add-Tabs $run 2);$target=$ids[0];$survivor=$ids[1]
    Select-Pid $run $target
    [TabBarTestNative]::Key((Children $run)[0],0x58)
    Wait-For $run 'modal target child records running input' {$s=State $run $target;return $s -and (@($s.Keys)-join ',') -eq 'x'}
    Select-Pid $run $survivor
    $survivorHwnd=@(Children $run)[0]
    Close-ByGesture $run 'middle' 0 2
    Wait-For $run 'modal reentrancy opens aggregate confirmation' {@(Dialogs $run).Count -eq 1}
    Capture-Dialog $run "modal-exit-$allChildren"
    Request-Exit $run $target
    if($allChildren){Request-Exit $run $survivor}
    if($allChildren){
        Wait-Until 'all controlled child PIDs exit during modal' {(-not (Child-ProcessAlive $target) -and -not (Child-ProcessAlive $survivor)) -or $run.Process.HasExited}
        if(-not $run.Process.HasExited -and @(Dialogs $run).Count -eq 1){Answer-Dialog $run 1}
        Wait-Until 'owner teardown completes after all children exit' {$run.Process.HasExited}
        Check ($run.Process.ExitCode -eq 0) 'close: all-owner modal exit shuts down cleanly' @{ExitCode=$run.Process.ExitCode}
        $diagnostics=$run.Stderr.GetAwaiter().GetResult()
        Check (-not $diagnostics.Contains('panic:')) 'close: all-owner modal exit has no panic' @{Stderr=$diagnostics}
        return
    }
    Wait-Until 'modal target child exits during dialog' {-not (Child-ProcessAlive $target)}
    Wait-Until 'target live terminal HWND retires during dialog' {@(Children $run $false).Count -eq 1 -or $run.Process.HasExited}
    if(-not $run.Process.HasExited -and @(Dialogs $run).Count -eq 1){Answer-Dialog $run 1}
    Wait-For $run 'modal target disappearance leaves the other tab selected' {@(Children $run $false).Count -eq 1 -and (Shell-Pid $run) -eq $survivor -and @(Children $run)[0] -eq $survivorHwnd}
    [TabBarTestNative]::Key((Children $run)[0],0x58)
    Wait-For $run 'surviving tab accepts input after modal reentrancy' {$s=State $run $survivor;return $s -and (@($s.Keys)-join ',') -eq 'x'}
    Check ((Child-ProcessAlive $survivor) -and (Shell-Pid $run) -eq $survivor) 'close: modal reentrancy preserves surviving HWND/PID' @{Survivor=$survivor}
    Stop-RunCleanly $run
    $diagnostics=$run.Stderr.GetAwaiter().GetResult()
    Check (-not $diagnostics.Contains('panic:') -and -not $diagnostics.Contains('surface thread wedged')) 'close: modal reentrancy exits without panic or thread-leak fallback' @{Stderr=$diagnostics}
}
function Run-FinalTab([string]$gesture,[bool]$confirm){
    $run=Start-Run 1.0 "close-final-$gesture-$confirm" $confirm
    $pidValue=Shell-Pid $run
    if($confirm){[TabBarTestNative]::Key((Children $run)[0],0x58);Wait-For $run 'final controlled child records running input' {$s=State $run $pidValue;return $s -and (@($s.Keys)-join ',') -eq 'x'}}
    Close-ByGesture $run $gesture 0 1
    if($confirm){
        Wait-For $run "$gesture final tab opens confirmation" {@(Dialogs $run).Count -eq 1}
        Capture-Dialog $run "$gesture-final-confirmation"
        Answer-Dialog $run 1
    }
    Check ($run.Process.WaitForExit(20000)) "close: $gesture final tab exits without forced termination" @{Gesture=$gesture;Confirm=$confirm}
    Check ($run.Process.ExitCode -eq 0) "close: $gesture final tab exits with code zero" @{ExitCode=$run.Process.ExitCode}
}
function Run-MiddleBoundaries{
    $run=Start-Run 1.0 'close-middle-boundaries' $false
    $ids=@(Add-Tabs $run 3);$active=$ids[1]
    Select-Pid $run $active
    $activeHwnd=@(Children $run)[0]
    [TabBarTestNative]::MiddlePlus($run.Top)
    [TabBarTestNative]::MiddleNegative($run.Top)
    [TabBarTestNative]::MiddleBelow($run.Top)
    [TabBarTestNative]::Key($activeHwnd,0x58)
    Wait-For $run 'plus, negative, and below-strip presses drain before key receipt' {$s=State $run $active;return $s -and (@($s.Keys)-join ',') -eq 'x'}
    Check (@(Children $run $false).Count -eq 3 -and (Shell-Pid $run) -eq $active) 'close: plus, negative, and below-strip presses are no-ops' @{Active=$active;Tabs=3}
    [TabBarTestNative]::MiddleSequence($run.Top,0,3)
    [TabBarTestNative]::Key($activeHwnd,0x59)
    Wait-For $run 'down-up-double-up sequence drains after exactly one close' {$s=State $run $active;return $s -and (@($s.Keys)-join ',') -eq 'x,y'}
    Check (@(Children $run $false).Count -eq 2 -and (Shell-Pid $run) -eq $active -and (Child-ProcessAlive $ids[2])) 'close: middle sequence does not close the tab shifted under cursor' @{Closed=$ids[0];Active=$active;Shifted=$ids[2]}
    [TabBarTestNative]::MiddleCloseRegion($run.Top,1,2)
    [TabBarTestNative]::Key($activeHwnd,0x5A)
    Wait-For $run 'middle press on tab X region drains after one close' {$s=State $run $active;return $s -and (@($s.Keys)-join ',') -eq 'x,y,z'}
    Check (@(Children $run $false).Count -eq 1 -and (Shell-Pid $run) -eq $active -and -not (Child-ProcessAlive $ids[2])) 'close: middle press in tab X region closes once' @{Closed=$ids[2];Active=$active}
    Stop-RunCleanly $run
    $hidden=Start-Run 1.0 'close-middle-hidden' $false 'never'
    $hiddenIds=@(Add-Tabs $hidden 2);$hiddenActive=$hiddenIds[1];$hiddenHwnd=@(Children $hidden)[0]
    [TabBarTestNative]::MiddleTab($hidden.Top,0,2)
    [TabBarTestNative]::Key($hiddenHwnd,0x58)
    Wait-For $hidden 'hidden-strip middle press drains before key receipt' {$s=State $hidden $hiddenActive;return $s -and (@($s.Keys)-join ',') -eq 'x'}
    Check (@(Children $hidden $false).Count -eq 2 -and (Shell-Pid $hidden) -eq $hiddenActive) 'close: hidden strip ignores middle presses' @{Active=$hiddenActive;Tabs=2}
    Stop-RunCleanly $hidden
}
function Run-TerminalMiddleBoundary{
    $run=Start-Run 1.0 'close-terminal-middle-input' $false
    $pidValue=Shell-Pid $run;$surface=@(Children $run)[0]
    Request-MouseReporting $run $pidValue
    Wait-For $run 'terminal fixture enables mouse reporting' {Test-Path (Join-Path $run.State "mouse-ready-$pidValue")}
    Wait-For $run 'mouse-reporting title acknowledgment' {[TabBarTestNative]::Text($run.Top) -eq "tab-probe-$pidValue-mouse"}
    [TabBarTestNative]::TerminalMiddle($surface)
    [TabBarTestNative]::Key($surface,0x58)
    Wait-For $run 'terminal receives subsequent key after middle input' {$s=State $run $pidValue;return $s -and @($s.Keys).Count -ge 1 -and $s.Keys[-1] -eq 'x'}
    Check (@(Children $run $false).Count -eq 1 -and (Shell-Pid $run) -eq $pidValue -and (Child-ProcessAlive $pidValue)) 'close: terminal child middle down/up leaves tab identity intact' @{Pid=$pidValue}
    Stop-RunCleanly $run
}
function Invoke-CloseScenarios{
    Run-MiddleActive
    Run-MiddleActiveNonRightmost
    Run-InactiveIdentity 'middle' 0
    Run-InactiveIdentity 'middle' 2
    Run-InactiveIdentity 'x' 0
    Run-InactiveIdentity 'x' 2
    Run-Confirm 'x' $false
    Run-Confirm 'x' $true
    Run-Confirm 'middle' $false
    Run-Confirm 'middle' $true
    Run-Confirm 'x' $true $true
    Run-Confirm 'middle' $true $true
    Run-SplitProtection 'x' $false
    Run-SplitProtection 'x' $true
    Run-SplitProtection 'middle' $false
    Run-SplitProtection 'middle' $true
    Run-ModalExit $false
    Run-ModalExit $true
    Run-FinalTab 'x' $false
    Run-FinalTab 'middle' $false
    Run-FinalTab 'x' $true
    Run-FinalTab 'middle' $true
    Run-MiddleBoundaries
    Run-TerminalMiddleBoundary
}
try{
    $modes=if($Case -eq 'all'){@(@{Name='opaque';Opacity=1.0},@{Name='transparent';Opacity=0.8},@{Name='light';Opacity=1.0},@{Name='close';Opacity=1.0})}elseif($Case -eq 'close'){@(@{Name='close';Opacity=1.0})}elseif($Case -eq 'transparent'){@(@{Name='transparent';Opacity=0.8})}else{@(@{Name=$Case;Opacity=1.0})}
    foreach($mode in $modes){
        if($mode.Name -eq 'close'){
            $current=Start-Run 1.0 'close-x-cancel' $true
            $active=@(Children $current)[0];$activePid=Shell-Pid $current
            [TabBarTestNative]::Key($active,0x58)
            Wait-For $current 'X-cancel fixture records running-child input' {$state=State $current $activePid;return $state -and (@($state.Keys)-join ',') -eq 'x'}
            [TabBarTestNative]::CloseTab($current.Top,0,1)
            Wait-For $current 'X-button close opens running-process confirmation' {@(Dialogs $current).Count -eq 1}
            Capture-Dialog $current 'x-cancel-confirmation'
            Answer-Dialog $current 2
            Wait-For $current 'X-button cancellation dismisses confirmation' {@(Dialogs $current).Count -eq 0}
            Wait-For $current 'X-button cancellation preserves the active terminal' {@(Children $current).Count -eq 1 -and (Shell-Pid $current) -eq $activePid}
            Check ((Children $current)[0] -eq $active) 'close: cancel preserves active surface identity' @{Pid=$activePid}
            Screenshot $current 'x-cancel'
            Request-Exit $current $activePid
            Check ($current.Process.WaitForExit(20000)) 'close: X-cancel fixture exits after its child is released' @{}
            Check ($current.Process.ExitCode -eq 0) 'close: X-cancel fixture exit code is zero' @{ExitCode=$current.Process.ExitCode}
            Invoke-CloseScenarios
            continue
        }
        $current=Start-Run $mode.Opacity $mode.Name
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
        Check ($current.Process.WaitForExit(20000)) "$($mode.Name): closing the test window exits without forced termination" @{}
        Check ($current.Process.ExitCode -eq 0) "$($mode.Name): app exit succeeds" @{ExitCode=$current.Process.ExitCode}
    }
    $record.Status='passed'
}catch{
    $record.Errors+=$_.Exception.ToString();$record.Errors+=$_.ScriptStackTrace
    if($current -and -not $current.Process.HasExited -and $current.Top){try{Screenshot $current 'failure'}catch{$record.Errors+='Capture: '+$_.Exception.Message}}
}finally{
    foreach($run in $runs){
        [TabBarTestNative]::ProcessId=$run.Process.Id
        if(-not $run.Process.HasExited){
            foreach($pidValue in @(Child-Pids $run)){Request-Exit $run $pidValue}
            if(-not $run.Process.WaitForExit(10000)){
                foreach($dialog in @(Dialogs $run)){[void][TabBarTestNative]::DialogCommand($dialog,1)}
                if(-not $run.Process.WaitForExit(5000)){$run.Process.Kill($true);$run.Process.WaitForExit()}
            }
        }
        [IO.File]::WriteAllText((Join-Path $OutputDirectory ($run.Name+'.stdout.log')),$run.Stdout.GetAwaiter().GetResult())
        [IO.File]::WriteAllText((Join-Path $OutputDirectory ($run.Name+'.stderr.log')),$run.Stderr.GetAwaiter().GetResult())
    }
    $record|ConvertTo-Json -Depth 10|Set-Content (Join-Path $OutputDirectory 'tab-bar-results.json')
    Remove-Item -LiteralPath $work -Recurse -Force
}
Write-Host "Native tab bar: $($record.Status); evidence: $OutputDirectory"
if($record.Status -ne 'passed'){exit 1}
