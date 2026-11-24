param(
    [Parameter(Mandatory)][string]$ExePath,
    [Parameter(Mandatory)][string]$ResourcesPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('opaque','transparent','light','close','close-splits','startup','appearance','indicators','graphics','pane-drag','native-settings','pane-menu','all')][string]$Case='all'
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
    public static Rect PaneBounds(IntPtr h){Rect rect;if(!GetWindowRect(Check(h),out rect))throw new Exception("Missing test window bounds");return rect;}
    public static IntPtr Grip(IntPtr pane){
        var bounds=PaneBounds(pane);
        foreach(var h in Find("GhosttyPaneDrag",IntPtr.Zero,true)){
            var r=PaneBounds(h);
            if(r.Top==bounds.Top && Math.Abs((r.Left+r.Right)-(bounds.Left+bounds.Right))<=2)return h;
        }
        return IntPtr.Zero;
    }
    public static void DragStart(IntPtr grip){var r=Client(grip);Post(grip,0x201,1,Coordinates(r.Width/2,(r.Bottom-r.Top)/2));}
    [StructLayout(LayoutKind.Sequential)] struct GuiState { public uint size,flags; public IntPtr active,focus,capture,menu,move,caret; public Rect bounds; }
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint thread,ref GuiState info);
    static GuiState GuiFor(IntPtr pane){uint pid;uint thread=GetWindowThreadProcessId(Check(pane),out pid);var state=new GuiState{size=(uint)Marshal.SizeOf<GuiState>()};if(!GetGUIThreadInfo(thread,ref state))throw new Exception("GUI state unavailable");return state;}
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetMenuString(IntPtr menu,uint item,StringBuilder text,int length,uint flags);
    [DllImport("user32.dll")] static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")] static extern uint GetMenuState(IntPtr menu,uint item,uint flags);
    const uint MN_GETHMENU=0x1e1,MN_SELECTITEM=0x1e5,MF_BYPOSITION=0x400,MF_HILITE=0x80;
    static IntPtr MenuHandle(IntPtr popup){return new IntPtr(Message(popup,MN_GETHMENU,0,IntPtr.Zero));}
    public static int MenuIndex(IntPtr popup,string title){
        var menu=MenuHandle(popup);
        for(uint i=0;i<GetMenuItemCount(menu);i++){
            var text=new StringBuilder(128);
            if(GetMenuString(menu,i,text,text.Capacity,MF_BYPOSITION)>0 && text.ToString()==title && (GetMenuState(menu,i,MF_BYPOSITION)&3)==0)return (int)i;
        }
        return -1;
    }
    public static void ChooseMenuItem(IntPtr popup,string title){
        int index=MenuIndex(popup,title);
        if(index<0)throw new Exception("Menu item unavailable: "+title);
        var handle=MenuHandle(popup);
        // First highlight by position, then dispatch Return to the native
        // menu owner. Both HWNDs belong to this staged application.
        Message(popup,MN_SELECTITEM,index,IntPtr.Zero);
        if((GetMenuState(handle,(uint)index,MF_BYPOSITION)&MF_HILITE)==0)throw new Exception("Menu could not highlight "+title);
        Key(GuiFor(popup).menu,0x0d);
    }
    public static IntPtr Captured(IntPtr pane){return GuiFor(pane).capture;}
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    public static bool Foreground(IntPtr top){return GetForegroundWindow()==Check(top);}
    public static IntPtr Focus(IntPtr pane){return GuiFor(pane).focus;}
    public static void DragEnd(IntPtr grip,IntPtr target,int x,int y){
        var a=PaneBounds(grip);var b=PaneBounds(target);
        long point=Coordinates(b.Left+b.Width*x/100-a.Left,b.Top+(b.Bottom-b.Top)*y/100-a.Top);
        Post(grip,0x200,1,point);Post(grip,0x202,0,point);
    }
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h,ref Point p);
    public static void DragToTab(IntPtr grip,IntPtr top,int index,int count){
        var p=new Point(TabX(top,index,count),TabY(top));var a=PaneBounds(grip);
        if(!ClientToScreen(Check(top),ref p))throw new Exception("Tab is unavailable");
        long point=Coordinates(p.X-a.Left,p.Y-a.Top);Post(grip,0x200,1,point);Post(grip,0x202,0,point);
    }
    public static void PositionPair(IntPtr first,IntPtr second){
        SetThreadDpiAwarenessContext(new IntPtr(-4));
        if(!SetWindowPos(Check(first),IntPtr.Zero,10,30,480,460,0x54)||
           !SetWindowPos(Check(second),IntPtr.Zero,500,30,480,460,0x54))throw new Exception("Could not place the two test windows");
    }
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr hwnd);
    public static int PaneRed(IntPtr top,IntPtr pane){
        Rect outer,child;
        if(!GetWindowRect(Check(top),out outer)||!GetWindowRect(Check(pane),out child))
            throw new Exception("GetWindowRect failed");
        using(var bitmap=new Bitmap(outer.Width,outer.Bottom-outer.Top)){
            using(var graphics=Graphics.FromImage(bitmap)){
                var dc=graphics.GetHdc();
                try{if(!PrintWindow(top,dc,2))throw new Exception("PrintWindow failed");}
                finally{graphics.ReleaseHdc(dc);}
            }
            return bitmap.GetPixel((child.Left+child.Right)/2-outer.Left,(child.Top+child.Bottom)/2-outer.Top).R;
        }
    }
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent,IntPtr after,string cls,string title);
    public static IntPtr MessageWindow(){
        var h=IntPtr.Zero;
        while((h=FindWindowEx(new IntPtr(-3),h,"GhosttyMsg",null))!=IntPtr.Zero){
            uint pid;GetWindowThreadProcessId(h,out pid);
            if(pid==(uint)ProcessId)return h;
        }
        return IntPtr.Zero;
    }
    [StructLayout(LayoutKind.Sequential)] struct MonitorInfo { public int size;public Rect monitor,work;public int flags; }
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hwnd,uint fallback);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor,ref MonitorInfo info);
    public static bool CenteredOnEdge(IntPtr hwnd,string edge){
        SetThreadDpiAwarenessContext(new IntPtr(-4));
        var info=new MonitorInfo{size=Marshal.SizeOf<MonitorInfo>()};
        Rect r;
        if(!GetWindowRect(Check(hwnd),out r)||!GetMonitorInfo(MonitorFromWindow(hwnd,2),ref info))throw new Exception("Window geometry unavailable");
        var work=info.work;
        if(edge=="top"||edge=="bottom")
            return (edge=="top"?r.Top==work.Top:r.Bottom==work.Bottom) && r.Bottom-r.Top==280 &&
                Math.Abs(2*r.Width-work.Width)<=1 && Math.Abs(r.Left+r.Right-work.Left-work.Right)<=1;
        return (edge=="left"?r.Left==work.Left:r.Right==work.Right) && r.Width==280 &&
            Math.Abs(2*(r.Bottom-r.Top)-(work.Bottom-work.Top))<=1 && Math.Abs(r.Top+r.Bottom-work.Top-work.Bottom)<=1;
    }
    public static bool Maximized(IntPtr hwnd){return IsZoomed(Check(hwnd));}
    public static bool Captioned(IntPtr hwnd){return (GetWindowLongPtr(Check(hwnd),-16).ToInt64() & 0xC00000) != 0;}
    public static string Bounds(IntPtr hwnd){Rect r;if(!GetWindowRect(Check(hwnd),out r))throw new Exception("GetWindowRect failed");return string.Format("{0},{1},{2},{3}",r.Left,r.Top,r.Right,r.Bottom);}
    public static int Width(IntPtr hwnd){return Client(hwnd).Width;}
    public static void MiddleDuringDividerDrag(IntPtr top,int index,int count){
        var client=Client(top);
        int y=client.Bottom/2;
        Post(top,0x201,1,Coordinates(client.Width/2,y));
        Post(top,0x200,1,Coordinates(2*client.Width/3,y));
        long tab=Coordinates(TabX(top,index,count),TabY(top));
        Post(top,0x207,0x11,tab);
        Post(top,0x208,1,tab);
        Post(top,0x202,0,tab);
    }
    public static Point[] ImageMarkers(IntPtr top,IntPtr pane){
        Rect outer,child;
        if(!GetWindowRect(Check(top),out outer)||!GetWindowRect(Check(pane),out child))throw new Exception("Window geometry unavailable");
        var points=new[]{new Point(-1,-1),new Point(-1,-1),new Point(-1,-1)};
        using(var bitmap=new Bitmap(outer.Width,outer.Bottom-outer.Top)){
            using(var g=Graphics.FromImage(bitmap)){
                var dc=g.GetHdc();try{if(!PrintWindow(top,dc,2))throw new Exception("PrintWindow failed");}finally{g.ReleaseHdc(dc);}
            }
            for(int y=child.Top-outer.Top;y<child.Bottom-outer.Top;y+=3){
                for(int x=child.Left-outer.Left;x<child.Right-outer.Left;x+=3){
                    var c=bitmap.GetPixel(x,y);
                    int i=c.R>220&&c.G<25&&c.B<25?0:c.G>220&&c.R<25&&c.B<25?1:c.B>220&&c.R<25&&c.G<25?2:-1;
                    if(i>=0&&points[i].X<0)points[i]=new Point(x,y);
                }
            }
        }
        return points;
    }
    public static Bitmap WindowBitmap(IntPtr top){
        Rect rect;if(!GetWindowRect(Check(top),out rect))throw new Exception("GetWindowRect failed");
        var bitmap=new Bitmap(rect.Width,rect.Bottom-rect.Top);
        try{
            using(var graphics=Graphics.FromImage(bitmap)){var dc=graphics.GetHdc();try{if(!PrintWindow(Check(top),dc,2))throw new Exception("PrintWindow failed");}finally{graphics.ReleaseHdc(dc);}}
            return bitmap;
        }catch{bitmap.Dispose();throw;}
    }
    public static void Capture(IntPtr top,string path){
        using(var bitmap=WindowBitmap(top))bitmap.Save(path,ImageFormat.Png);
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
function Save-State {
    # A reader can hold an older snapshot while the next one is published.
    $statePath=Join-Path $env:GHOSTTY_TAB_TEST_STATE ('{0}-{1:D10}.json' -f $PID,$keys.Count)
    $json=@{Pid=$PID;Keys=$keys.ToArray();Columns=[Console]::WindowWidth;Rows=[Console]::WindowHeight;QuickTerminal=$env:GHOSTTY_QUICK_TERMINAL;SurfaceId=$env:GHOSTTY_SURFACE_ID}|ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText("$statePath.tmp",$json)
    [IO.File]::Move("$statePath.tmp",$statePath)
}
function Kitty([string]$payload){
    [Console]::Write([char]27 + '_G' + $payload + [char]27 + '\')
}
$titleSuffix=''
if(Test-Path (Join-Path $env:GHOSTTY_TAB_TEST_STATE "prompt-$PID")){$titleSuffix='-prompt'}
Save-State
New-Item -ItemType File -Force (Join-Path $env:GHOSTTY_TAB_TEST_STATE "live-$PID")|Out-Null
[Console]::Write("`e]2;tab-probe-$PID$titleSuffix`a`e[2J`e[Htab-probe-$PID`r`n")
while($true){
    if(Test-Path (Join-Path $env:GHOSTTY_TAB_TEST_STATE "exit-$PID")){Remove-Item (Join-Path $env:GHOSTTY_TAB_TEST_STATE "live-$PID") -Force -ErrorAction SilentlyContinue;exit 0}
    if($env:GHOSTTY_SETTINGS_TEST){
        $history=Join-Path $env:GHOSTTY_TAB_TEST_STATE "history-$PID"
        if(Test-Path -LiteralPath $history){
            [Console]::Write([IO.File]::ReadAllText($history))
            [Console]::Out.Flush()
            Remove-Item -LiteralPath $history
        }
    }
    if($env:GHOSTTY_GRAPHICS_TEST){
        $request=Join-Path $env:GHOSTTY_TAB_TEST_STATE 'image-request'
        if(Test-Path -LiteralPath $request){
            $stage=[IO.File]::ReadAllText($request)
            Remove-Item -LiteralPath $request
            switch($stage){
                'place' {
                    [Console]::Write("`e[6;6H")
                    Kitty 'a=T,i=1,p=1,f=24,s=1,v=1,c=5,r=3,C=1,q=2;/wAA'
                    Kitty 'a=t,i=2,f=24,s=1,v=1,q=2;AP8A'
                    Kitty 'a=p,i=2,p=1,P=1,Q=1,H=7,V=1,c=4,r=2,C=1,q=2'
                }
                'move' {
                    [Console]::Write("`e[10;14H")
                    Kitty 'a=p,i=1,p=1,c=5,r=3,C=1,q=2'
                }
                'frame' {
                    Kitty 'a=f,i=1,f=24,s=1,v=1,z=180,q=2;AAD/'
                    Kitty 'a=a,i=1,c=2,q=2'
                }
                'animate' {
                    Kitty 'a=a,i=1,r=1,z=180,c=1,s=3,v=1,q=2'
                }
            }
            [Console]::Out.Flush()
        }
    }
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
function State($run,[int]$pidValue){
    $latest=Get-ChildItem -LiteralPath $run.State -Filter "$pidValue-*.json" |
        Sort-Object Name -Descending | Select-Object -First 1
    if($latest){return [IO.File]::ReadAllText($latest.FullName) | ConvertFrom-Json}
}
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
function Start-Run([double]$opacity,[string]$name,[bool]$confirm=$false,[string]$showTabBar='always',[string[]]$extraConfig=@(),[switch]$KeepStartupBounds,[switch]$BackgroundLaunch){
    $run=@{Name=$name;State=(Join-Path $work $name);Config=(Join-Path $work ($name+'.ghostty'))};New-Item -ItemType Directory $run.State|Out-Null
    $background=if($name -eq 'light'){'#ffffff'}else{'#1e1e2e'}
    $foreground=if($name -eq 'light'){'#1e1e2e'}else{'#ffffff'}
    $configLines=@(('command = pwsh.exe -NoLogo -NoProfile -File "'+$fixture+'"'),('background-opacity = '+$opacity.ToString([Globalization.CultureInfo]::InvariantCulture)),('background = '+$background),('foreground = '+$foreground),'background-blur = false','font-family = Consolas','font-size = 14',('window-show-tab-bar = '+$showTabBar),'shell-integration = none',('confirm-close-surface = '+$confirm.ToString().ToLowerInvariant()),'cursor-style-blink = false','auto-update = off','keybind = f9=new_tab','keybind = f4=next_tab')
    if($name.StartsWith('close-')){$configLines+='keybind = f8=new_split:right'}
    $configLines+=$extraConfig
    $configLines|Set-Content -Encoding utf8 $run.Config
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$stagedExecutable;$start.WorkingDirectory=$work;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.Environment['GHOSTTY_RESOURCES_DIR']=Join-Path $stagedShare 'ghostty';$start.Environment['GHOSTTY_TAB_TEST_STATE']=$run.State
    [void]$start.Environment.Remove('GHOSTTY_QUICK_TERMINAL')
    if($name -eq 'graphics'){$start.Environment['GHOSTTY_GRAPHICS_TEST']='1'}
    if($name -eq 'settings-scrollbar'){$start.Environment['GHOSTTY_SETTINGS_TEST']='1'}
    $start.ArgumentList.Add('--config-default-files=false');$start.ArgumentList.Add('--config-file='+$run.Config)
    $run.Process=[Diagnostics.Process]::Start($start);$runs.Add($run);$run.Stdout=$run.Process.StandardOutput.ReadToEndAsync();$run.Stderr=$run.Process.StandardError.ReadToEndAsync();$script:current=$run;$record.Runs+=@{Mode=$name;Pid=$run.Process.Id;ConfiguredOpacity=$opacity;ConfirmCloseSurface=$confirm;TabBar=$showTabBar}
    [TabBarTestNative]::ProcessId=$run.Process.Id
    if($BackgroundLaunch){
        Wait-For $run 'background message loop' {$run.MessageWindow=[TabBarTestNative]::MessageWindow();return $run.MessageWindow -ne [IntPtr]::Zero}
        [void][TabBarTestNative]::Message($run.MessageWindow,0,0,[IntPtr]::Zero)
        Check (@([TabBarTestNative]::Find('GhosttyWindow',[IntPtr]::Zero,$false)).Count -eq 0) 'background launch creates no normal window' @{}
        # Send the notification directly to this process after registration.
        # An unregistered binding has no dispatch entry and cannot open a terminal.
        [TabBarTestNative]::Post($run.MessageWindow,0x0312,1,0)
    }
    Wait-For $run 'initial native window' {$tops=@([TabBarTestNative]::Find('GhosttyWindow',[IntPtr]::Zero,$true));if($tops.Count -eq 1){$run.Top=$tops[0];return @(Children $run).Count -eq 1};return $false}
    if(-not $KeepStartupBounds){[TabBarTestNative]::Position($run.Top)}
    $run.Panes=@{}
    Wait-For $run 'initial terminal fixture' {
        $shell=Shell-Pid $run
        $visible=@(Children $run)
        if($visible.Count -ne 1 -or $shell -notin @(Child-Pids $run)){return $false}
        $run.Panes[$shell]=$visible[0]
        return $true
    }
    [TabBarTestNative]::Paint($run.Top)
    return $run
}
function Child-Pids($run){return @((Get-ChildItem -LiteralPath $run.State -Filter 'live-*' -ErrorAction SilentlyContinue)|ForEach-Object{[int]$_.Name.Substring(5)})}
function Child-ProcessAlive([int]$pidValue){return [bool](Get-Process -Id $pidValue -ErrorAction SilentlyContinue)}
function Visible-Tab($run,[int]$pidValue){
    $visible=@(Children $run)
    return $visible.Count -eq 1 -and $visible[0] -eq $run.Panes[$pidValue] -and (Shell-Pid $run) -eq $pidValue
}
function Select-Pid($run,[int]$pidValue){
    for($attempt=0;$attempt -lt $run.Panes.Count -and -not (Visible-Tab $run $pidValue);$attempt++){
        $prior=Shell-Pid $run
        [TabBarTestNative]::Key($run.Panes[$prior],0x73)
        Wait-For $run "select tab for child $pidValue" {
            $next=Shell-Pid $run
            return $next -ne $prior -and $run.Panes.ContainsKey($next) -and (Visible-Tab $run $next)
        }
    }
    if(-not (Visible-Tab $run $pidValue)){throw "Could not select tab for child $pidValue; active child is $(Shell-Pid $run)"}
}
function Add-Pane($run,[int]$sourcePid,[switch]$Split){
    $priorVisible=@(Children $run)
    $key=if($Split){0x77}else{0x78}
    [TabBarTestNative]::Key($run.Panes[$sourcePid],$key)
    Wait-For $run "new pane from child $sourcePid" {
        $allHwnds=@(Children $run $false)
        $allPids=@(Child-Pids $run)
        if($allHwnds.Count -ne $run.Panes.Count+1 -or $allPids.Count -ne $run.Panes.Count+1){return $false}
        $newHwnds=@($allHwnds | Where-Object {$_ -notin $run.Panes.Values})
        $newPids=@($allPids | Where-Object {-not $run.Panes.ContainsKey($_)})
        if($newHwnds.Count -ne 1 -or $newPids.Count -ne 1 -or (Shell-Pid $run) -ne $newPids[0]){return $false}
        # The new title can arrive while the outgoing tab is still visible.
        $visible=@(Children $run)
        if($newHwnds[0] -notin $visible){return $false}
        if($Split){
            if($visible.Count -ne $priorVisible.Count+1 -or @($priorVisible | Where-Object {$_ -notin $visible}).Count -ne 0){return $false}
        }elseif($visible.Count -ne 1){return $false}
        $run.Panes[$newPids[0]]=$newHwnds[0]
        return $true
    }
    return (Shell-Pid $run)
}
function Add-Tabs($run,[int]$count){
    $ids=[Collections.Generic.List[int]]::new()
    $ids.Add((Shell-Pid $run))
    while($ids.Count -lt $count){
        $ids.Add((Add-Pane $run $ids[-1]))
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
function Run-Graphics {
    $run=Start-Run 1.0 'graphics'
    $pane=@(Children $run)[0]
    $request=Join-Path $run.State 'image-request'
    # Publish complete commands; the child polls from its own ConPTY.
    function Stage([string]$name){
        [IO.File]::WriteAllText("$request.tmp",$name)
        [IO.File]::Move("$request.tmp",$request)
    }
    Stage 'place'
    Wait-For $run 'parent and relative child images rendered' {
        $points=[TabBarTestNative]::ImageMarkers($run.Top,$pane)
        return $points[0].X -ge 0 -and $points[1].X -gt $points[0].X
    }
    $before=[TabBarTestNative]::ImageMarkers($run.Top,$pane)
    Stage 'move'
    Wait-For $run 'child moves with its parent placement' {
        $p=[TabBarTestNative]::ImageMarkers($run.Top,$pane)
        return $p[0].X -gt $before[0].X+10 -and $p[0].Y -gt $before[0].Y+10 -and
            [Math]::Abs(($p[1].X-$before[1].X)-($p[0].X-$before[0].X)) -le 3 -and
            [Math]::Abs(($p[1].Y-$before[1].Y)-($p[0].Y-$before[0].Y)) -le 3
    }
    Stage 'frame'
    Wait-For $run 'client-selected blue frame rendered' {
        $p=[TabBarTestNative]::ImageMarkers($run.Top,$pane)
        return $p[0].X -lt 0 -and $p[1].X -ge 0 -and $p[2].X -ge 0
    }
    Stage 'animate'
    foreach($i in @(0,2,0,2)){
        Wait-For $run "automatic animation displays frame color $i" {
            return [TabBarTestNative]::ImageMarkers($run.Top,$pane)[$i].X -ge 0
        }
    }
    $hostVersion=(Get-Item -LiteralPath (Join-Path $work 'OpenConsole.exe')).VersionInfo.FileVersion
    $drivers=@(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion)
    Check $true 'ConPTY and WGL render animated and relative placements' @{OpenConsole=$hostVersion;DisplayDrivers=$drivers}
    Stop-RunCleanly $run
}
function Run-Indicators {
    $settings=@('keybind = f5=toggle_readonly','keybind = f2>f3=ignore','keybind = f1=activate_key_table:nav',
        'keybind = nav/f6=deactivate_key_table','keybind = f7=reload_config')
    $run=Start-Run 1.0 'indicators' -extraConfig $settings
    $first=Shell-Pid $run
    $pane=$run.Panes[$first]
    function StatusLabels {
        foreach($control in @([TabBarTestNative]::Find('Static',[IntPtr]::Zero,$true))){
            [TabBarTestNative]::Text($control)
        }
    }
    [TabBarTestNative]::Key($pane,0x71)
    Wait-For $run 'sequence prefix shown' {'f2' -in @(StatusLabels)}
    [TabBarTestNative]::Key($pane,0x72)
    Wait-For $run 'completed sequence cleared' {'f2' -notin @(StatusLabels)}
    [TabBarTestNative]::Key($pane,0x71)
    Wait-For $run 'second prefix shown' {'f2' -in @(StatusLabels)}
    [TabBarTestNative]::Key($pane,0x1B)
    Wait-For $run 'cancelled sequence cleared' {'f2' -notin @(StatusLabels)}
    [TabBarTestNative]::Key($pane,0x70)
    Wait-For $run 'active table shown' {'Key table nav' -in @(StatusLabels)}
    [TabBarTestNative]::Key($pane,0x75)
    Wait-For $run 'popped table cleared' {'Key table nav' -notin @(StatusLabels)}
    [TabBarTestNative]::Key($pane,0x74)
    Wait-For $run 'read-only shown' {'Read-only' -in @(StatusLabels)}
    [TabBarTestNative]::Key($pane,0x76)
    Wait-For $run 'read-only survives reload' {'Read-only' -in @(StatusLabels)}
    $second=Add-Pane $run $first
    Wait-For $run 'status follows selected writable tab' {'Read-only' -notin @(StatusLabels)}
    Select-Pid $run $first
    Wait-For $run 'return restores read-only status' {'Read-only' -in @(StatusLabels)}
    Request-Exit $run $first
    Wait-For $run 'closing selected pane clears its status' {(Shell-Pid $run) -eq $second -and 'Read-only' -notin @(StatusLabels)}
    Stop-RunCleanly $run
}
function Run-PaneDrag {
    $settings=@('drag-handle = always','keybind = f8=new_split:right','keybind = f7=new_window','keybind = f6=reload_config')
    $run=Start-Run 1.0 'pane-drag' -extraConfig $settings
    $a=Shell-Pid $run
    $left=$run.Panes[$a]
    Wait-For $run 'always shows a grip for an unsplit terminal' { [TabBarTestNative]::Grip($left) -ne [IntPtr]::Zero }
    $b=Add-Pane $run $a -Split
    $right=$run.Panes[$b]
    Wait-For $run 'two split handles' { [TabBarTestNative]::Grip($right) -ne [IntPtr]::Zero }
    $grip=[TabBarTestNative]::Grip($right)
    [TabBarTestNative]::DragStart($grip)
    Wait-For $run 'grip captured before cancel' { [TabBarTestNative]::Captured($right) -eq $grip }
    [TabBarTestNative]::Key($right,0x1B)
    [TabBarTestNative]::DragEnd($grip,$left,30,5)
    [TabBarTestNative]::Key($right,0x43)
    Wait-For $run 'child receives c after canceled drop' { $s=State $run $b; $s -and (@($s.Keys)-join '') -eq 'c' }
    Check (([TabBarTestNative]::PaneBounds($left)).Right -le ([TabBarTestNative]::PaneBounds($right)).Left -and (Shell-Pid $run) -eq $b) 'Escape preserves split layout and focus' @{}
    [TabBarTestNative]::DragStart($grip)
    [TabBarTestNative]::DragEnd($grip,$left,30,5)
    Wait-For $run 'pane moves above the target in the same tab' { ([TabBarTestNative]::PaneBounds($right)).Bottom -le ([TabBarTestNative]::PaneBounds($left)).Top }

    $c=Add-Pane $run $b
    $other=$run.Panes[$c]
    [TabBarTestNative]::TabClick($run.Top,0,2)
    Wait-For $run 'split tab reselected' { @(Children $run).Count -eq 2 -and [TabBarTestNative]::Grip($right) -ne [IntPtr]::Zero }
    $grip=[TabBarTestNative]::Grip($right)
    [TabBarTestNative]::DragStart($grip)
    [TabBarTestNative]::DragToTab($grip,$run.Top,1,2)
    Wait-For $run 'pane joins inactive destination tab' { $panes=@(Children $run); return $panes.Count -eq 2 -and $right -in $panes -and $other -in $panes }
    [TabBarTestNative]::Key($right,0x58)
    Wait-For $run 'original child receives x after moving between tabs' { $s=State $run $b; $s -and (@($s.Keys)-join '') -eq 'cx' }

    [TabBarTestNative]::Key($right,0x76)
    Wait-For $run 'second native window has a new child' { @([TabBarTestNative]::Find('GhosttyWindow',[IntPtr]::Zero,$true)).Count -eq 2 -and @(Child-Pids $run).Count -eq 4 }
    $second=@([TabBarTestNative]::Find('GhosttyWindow',[IntPtr]::Zero,$true) | Where-Object { $_ -ne $run.Top })[0]
    $fourth=[TabBarTestNative]::Find('GhosttyTerminal',$second,$true)[0]
    [TabBarTestNative]::PositionPair($run.Top,$second)
    # Move the only pane of the second window. The empty tab and its
    # container close only after the moved HWND is owned by the first window.
    Wait-For $run 'both windows positioned' { [TabBarTestNative]::Grip($fourth) -ne [IntPtr]::Zero -and ([TabBarTestNative]::PaneBounds($second)).Left -gt ([TabBarTestNative]::PaneBounds($run.Top)).Left }
    $grip=[TabBarTestNative]::Grip($fourth)
    [TabBarTestNative]::DragStart($grip)
    Wait-For $run 'cross-window drag has mouse capture' { [TabBarTestNative]::Captured($fourth) -eq $grip }
    [TabBarTestNative]::DragEnd($grip,$right,90,50)
    Wait-For $run 'cross-window transfer closes empty source window' { @([TabBarTestNative]::Find('GhosttyWindow',[IntPtr]::Zero,$true)).Count -eq 1 -and $fourth -in @(Children $run) }
    $d=Shell-Pid $run
    Check ($d -ne 0 -and $d -notin @($a,$b,$c) -and @(Child-Pids $run).Count -eq 4) 'cross-window move preserves all four children' @{Moved=$d}
    [TabBarTestNative]::Key($fourth,0x59)
    Wait-For $run 'same child receives y in its new window' { $s=State $run $d; $s -and (@($s.Keys)-join '') -eq 'y' }
    $grip=[TabBarTestNative]::Grip($fourth)
    [TabBarTestNative]::DragStart($grip)
    Wait-For $run 'exiting pane has mouse capture' { [TabBarTestNative]::Captured($fourth) -eq $grip }
    Request-Exit $run $d
    Wait-For $run 'source exits during a drag' { $fourth -notin @(Children $run) -and $grip -notin @([TabBarTestNative]::Find('GhosttyPaneDrag',[IntPtr]::Zero,$false)) }
    [TabBarTestNative]::Key($right,0x5A)
    Wait-For $run 'surviving pane receives input after interrupted drag' { $s=State $run $b; $s -and (@($s.Keys)-join '') -eq 'cxz' }
    Add-Content -LiteralPath $run.Config 'drag-handle = never'
    [TabBarTestNative]::Key($right,0x75)
    Wait-For $run 'never hides every grip' { @([TabBarTestNative]::Find('GhosttyPaneDrag',[IntPtr]::Zero,$true)).Count -eq 0 }
    Add-Content -LiteralPath $run.Config 'drag-handle = auto'
    [TabBarTestNative]::Key($right,0x75)
    Wait-For $run 'auto restores split grips' { [TabBarTestNative]::Grip($right) -ne [IntPtr]::Zero }
    [TabBarTestNative]::TabClick($run.Top,0,2)
    Wait-For $run 'auto hides the unsplit tab grip' { @(Children $run).Count -eq 1 -and @([TabBarTestNative]::Find('GhosttyPaneDrag',[IntPtr]::Zero,$true)).Count -eq 0 }
    Stop-RunCleanly $run
}
function Run-Appearance {
    foreach ($opacity in @(1.0,0.8)) {
        $mode=if($opacity -eq 1.0){'opaque'}else{'transparent'}
        $settings=@('keybind = f8=new_split:right','keybind = f7=goto_split:previous',
            'keybind = f6=reload_config','unfocused-split-fill = #ff0000','unfocused-split-opacity = 0.25')
        $run=Start-Run $opacity "appearance-$mode" -extraConfig $settings
        $first=Shell-Pid $run
        $split=Add-Pane $run $first -Split
        $left=$run.Panes[$first]
        $right=$run.Panes[$split]
        Wait-For $run "$mode left pane has configured red fill" {
            $a=[TabBarTestNative]::PaneRed($run.Top,$left)
            $b=[TabBarTestNative]::PaneRed($run.Top,$right)
            return $b -ge 0 -and $a -gt ($b+90)
        }
        [TabBarTestNative]::Key($right,0x76)
        Wait-For $run "$mode red fill follows focus" {
            $a=[TabBarTestNative]::PaneRed($run.Top,$left)
            $b=[TabBarTestNative]::PaneRed($run.Top,$right)
            return $a -ge 0 -and $b -gt ($a+90)
        }
        Add-Content -LiteralPath $run.Config 'unfocused-split-opacity = 1'
        [TabBarTestNative]::Key($left,0x75)
        Wait-For $run "$mode reload removes the inactive pane tint" {
            $a=[TabBarTestNative]::PaneRed($run.Top,$left)
            $b=[TabBarTestNative]::PaneRed($run.Top,$right)
            return $a -ge 0 -and $b -ge 0 -and [Math]::Abs($a-$b) -lt 20
        }
        Stop-RunCleanly $run
    }
}
function Run-Startup {
    foreach ($edge in @('top','bottom','left','right')) {
        $settings=@('initial-window = false','keybind = clear',
            'keybind = global:ctrl+alt+shift+f11=toggle_quick_terminal','keybind = f8=new_split:right',
            'quick-terminal-animation-duration = 0','quick-terminal-autohide = false',
            'quick-terminal-screen = main',"quick-terminal-position = $edge",'quick-terminal-size = 280px,50%')
        $run=Start-Run 1.0 "startup-quick-$edge" -extraConfig $settings -KeepStartupBounds -BackgroundLaunch
        Check ([TabBarTestNative]::CenteredOnEdge($run.Top,$edge)) "quick terminal centers on $edge edge" @{}
        $first=Shell-Pid $run
        Wait-For $run 'quick-terminal child receives its environment marker' { (State $run $first).QuickTerminal -eq '1' }
        if($edge -eq 'top'){
            $split=Add-Pane $run $first -Split
            Wait-For $run 'new quick-terminal split receives its environment marker' { (State $run $split).QuickTerminal -eq '1' }
            $ids=@((State $run $first).SurfaceId,(State $run $split).SurfaceId)
            Check ($ids[0] -match '^0x[0-9a-f]{16}$' -and $ids[1] -match '^0x[0-9a-f]{16}$' -and $ids[0] -ne $ids[1]) 'quick-terminal children receive distinct surface IDs' @{}
        }
        Stop-RunCleanly $run
    }
    foreach ($preserve in @($false,$true)) {
        $policy=if($preserve){'navigation'}else{'no-navigation'}
        $settings=@('window-width = 66','window-height = 18','scrollbar = never',
            'window-padding-x = 7','window-padding-y = 5','keybind = f8=new_split:right',
            'keybind = f7=toggle_split_zoom','keybind = f6=goto_split:previous',
            ('split-preserve-zoom = '+$policy))
        $run=Start-Run 1.0 "startup-$policy" -extraConfig $settings -KeepStartupBounds
        $first=Shell-Pid $run
        $firstHwnd=$run.Panes[$first]
        # Read the child PTY dimensions after the final native layout.
        [TabBarTestNative]::Key($firstHwnd,0x58)
        Wait-For $run 'configured child grid' {
            $snapshot=State $run $first
            return $snapshot -and $snapshot.Columns -eq 66 -and $snapshot.Rows -eq 18
        }
        Check ([string]::IsNullOrEmpty((State $run $first).QuickTerminal)) 'normal terminal child has no quick-terminal marker' @{}
        Check (@([TabBarTestNative]::Find('GhosttyScrollbar',[IntPtr]::Zero,$true)).Count -eq 0) 'scrollbar=never hides all native scrollbars' @{}
        [TabBarTestNative]::Position($run.Top)
        $bounds=[TabBarTestNative]::Bounds($run.Top)
        $tab=Add-Pane $run $first
        Check ([TabBarTestNative]::Bounds($run.Top) -eq $bounds) 'new tab preserves resized window bounds' @{}
        $split=Add-Pane $run $tab -Split
        Check ([TabBarTestNative]::Bounds($run.Top) -eq $bounds) 'new split preserves resized window bounds' @{}
        [TabBarTestNative]::Key($run.Panes[$split],0x76)
        Wait-For $run 'active split zoomed' {@(Children $run).Count -eq 1 -and $run.Panes[$split] -in @(Children $run)}
        [TabBarTestNative]::Key($run.Panes[$split],0x75)
        $count=if($preserve){1}else{2}
        Wait-For $run "split navigation $policy" {@(Children $run).Count -eq $count -and $run.Panes[$tab] -in @(Children $run)}
        Stop-RunCleanly $run
    }
    foreach ($setting in @('maximize','fullscreen')) {
        $run=Start-Run 1.0 "startup-$setting" -extraConfig @("$setting = true") -KeepStartupBounds
        if($setting -eq 'maximize'){
            Check ([TabBarTestNative]::Maximized($run.Top)) 'normal window starts maximized' @{}
        }else{
            Check (-not [TabBarTestNative]::Captioned($run.Top)) 'fullscreen starts without a caption' @{}
        }
        Stop-RunCleanly $run
    }
}
function Run-MiddleActive{
    $run=Start-Run 1.0 'close-middle-active' $false
    $ids=@(Add-Tabs $run 2);$prior=$ids[0];$target=$ids[1]
    Close-ByGesture $run 'middle' 1 2
    Wait-For $run 'middle press closes active non-final tab and selects predecessor' {@(Children $run $false).Count -eq 1 -and (Shell-Pid $run) -eq $prior -and -not (Child-ProcessAlive $target)}
    Check (Visible-Tab $run $prior) 'close: active middle-close selects preceding tab' @{Previous=$prior;Closed=$target}
    Stop-RunCleanly $run
    Check ($run.Process.ExitCode -eq 0) 'close: active-tab fixture exits cleanly' @{ExitCode=$run.Process.ExitCode}
}
function Run-MiddleActiveNonRightmost{
    $run=Start-Run 1.0 'close-middle-active-middle' $false
    $ids=@(Add-Tabs $run 3);$target=$ids[1];$successor=$ids[2]
    Select-Pid $run $target
    Close-ByGesture $run 'middle' 1 3
    Wait-For $run 'middle press closes active middle tab and selects successor' {@(Children $run $false).Count -eq 2 -and (Shell-Pid $run) -eq $successor -and -not (Child-ProcessAlive $target)}
    Check (Visible-Tab $run $successor) 'close: active middle-tab close selects its successor' @{Closed=$target;Successor=$successor}
    Stop-RunCleanly $run
    Check ($run.Process.ExitCode -eq 0) 'close: active middle-tab fixture exits cleanly' @{ExitCode=$run.Process.ExitCode}
}
function Run-InactiveIdentity([string]$gesture,[int]$index){
    $run=Start-Run 1.0 "close-$gesture-inactive-$index" $false
    $ids=@(Add-Tabs $run 3);$active=$ids[1];$target=$ids[$index]
    Select-Pid $run $active
    $activeHwnd=$run.Panes[$active]
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
    $activeHwnd=$run.Panes[$active]
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
    $target=Add-Pane $run $original -Split
    $other=$original
    $splitHwnds=@($run.Panes[$original],$run.Panes[$target])
    Request-Prompt $run $target
    Wait-For $run 'focused split emits prompt title acknowledgment' {[TabBarTestNative]::Text($run.Top) -eq "tab-probe-$target-prompt"}
    $survivor=Add-Pane $run $target
    $survivorHwnd=$run.Panes[$survivor]
    [TabBarTestNative]::Paint($run.Top)
    Close-ByGesture $run $gesture 0 2
    Wait-For $run "$gesture split close prompts for non-focused running split" {@(Dialogs $run).Count -eq 1}
    Capture-Dialog $run "$gesture-split-$approve"
    Answer-Dialog $run $(if($approve){1}else{2})
    Wait-For $run "$gesture split confirmation is dismissed" {@(Dialogs $run).Count -eq 0}
    if($approve){
        Wait-For $run "$gesture OK closes both target splits only" {@(Children $run $false).Count -eq 1 -and (Shell-Pid $run) -eq $survivor -and -not (Child-ProcessAlive $target) -and -not (Child-ProcessAlive $other) -and @(Children $run)[0] -eq $survivorHwnd}
    }else{
        Wait-For $run "$gesture Cancel retains unrelated tab and both splits" {@(Children $run $false).Count -eq 3 -and (Shell-Pid $run) -eq $survivor}
        Check ((Child-ProcessAlive $target) -and (Child-ProcessAlive $other) -and (Visible-Tab $run $survivor) -and (Child-ProcessAlive $survivor) -and @($splitHwnds|Where-Object{$_ -notin @(Children $run $false)}).Count -eq 0) "close: $gesture split Cancel preserves both split HWNDs and active identity" @{Representative=$target;OtherSplit=$other;Survivor=$survivor}
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
    $survivorHwnd=$run.Panes[$survivor]
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
    $activeHwnd=$run.Panes[$active]
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
function Run-DividerDragMiddle{
    $run=Start-Run 1.0 'close-divider-drag' $false
    $tabs=@(Add-Tabs $run 2)
    [void](Add-Pane $run $tabs[1] -Split)
    [TabBarTestNative]::Paint($run.Top)
    [TabBarTestNative]::MiddleDuringDividerDrag($run.Top,1,2)
    Wait-For $run 'divider moved and both panes remain visible after middle-click' {
        $panes=@(Children $run)
        $width=[TabBarTestNative]::Width($run.Top)
        $panes.Count -eq 2 -and @($panes|Where-Object{[TabBarTestNative]::Width($_) -gt $width*0.6}).Count -eq 1
    }
    Check (@(Children $run $false).Count -eq 3 -and (Child-ProcessAlive $tabs[0])) 'close: middle-click during divider drag preserves both tabs' @{}
    Stop-RunCleanly $run
}
function Run-RepresentativeExit{
    $run=Start-Run 1.0 'close-representative-exit' $true
    $survivor,$sibling=@(Add-Tabs $run 2)
    $survivorHwnd=$run.Panes[$survivor]
    $representative=Add-Pane $run $sibling -Split
    [TabBarTestNative]::Paint($run.Top)
    Close-ByGesture $run 'middle' 1 2
    Wait-For $run 'split tab opens one confirmation' {@(Dialogs $run).Count -eq 1}
    Request-Exit $run $representative
    Wait-For $run 'representative exits before confirmation is answered' {
        -not (Child-ProcessAlive $representative) -and @(Children $run $false).Count -eq 2 -and @(Dialogs $run).Count -eq 1
    }
    Answer-Dialog $run 1
    Wait-For $run 'approval closes the surviving sibling only' {
        -not (Child-ProcessAlive $sibling) -and @(Children $run $false).Count -eq 1 -and @(Children $run)[0] -eq $survivorHwnd
    }
    Check ((Child-ProcessAlive $survivor) -and (Shell-Pid $run) -eq $survivor) 'close: confirmed tab still closes after its representative exits' @{Survivor=$survivor}
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
    Run-DividerDragMiddle
    Run-RepresentativeExit
}
try{
    $modes=if($Case -eq 'all'){@(@{Name='opaque';Opacity=1.0},@{Name='transparent';Opacity=0.8},@{Name='light';Opacity=1.0},@{Name='close';Opacity=1.0},@{Name='startup';Opacity=1.0},@{Name='appearance';Opacity=1.0},@{Name='indicators';Opacity=1.0},@{Name='graphics';Opacity=1.0},@{Name='pane-drag';Opacity=1.0},@{Name='native-settings';Opacity=1.0},@{Name='pane-menu';Opacity=1.0})}elseif($Case -eq 'close'){@(@{Name='close';Opacity=1.0})}elseif($Case -eq 'transparent'){@(@{Name='transparent';Opacity=0.8})}else{@(@{Name=$Case;Opacity=1.0})}
    foreach($mode in $modes){
        if($mode.Name -eq 'pane-menu'){
            . (Join-Path $PSScriptRoot 'test_pane_menu.ps1')
            Run-PaneMenu
            continue
        }
        if($mode.Name -eq 'native-settings'){
            . (Join-Path $PSScriptRoot 'test_native_settings.ps1')
            Run-NativeSettings
            continue
        }
        if($mode.Name -eq 'pane-drag'){Run-PaneDrag;continue}
        if($mode.Name -eq 'graphics'){Run-Graphics;continue}
        if($mode.Name -eq 'indicators'){Run-Indicators;continue}
        if($mode.Name -eq 'appearance'){Run-Appearance;continue}
        if($mode.Name -eq 'startup'){Run-Startup;continue}
        if($mode.Name -eq 'close-splits'){
            Run-DividerDragMiddle
            Run-RepresentativeExit
            continue
        }
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
