param(
    [Parameter(Mandatory)][string]$ExePath,
    [Parameter(Mandatory)][string]$ResourcesPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('opacity', 'blur', 'chrome', 'creation', 'lifecycle', 'all')][string]$Case = 'all'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)

$nativeReferences = @('System.Drawing.Common','System.Drawing.Primitives','System.Windows.Forms','System.Private.Windows.Core','System.Threading','System.Runtime.InteropServices','System.ComponentModel.Primitives','System.Collections','System.Threading.Thread','System.Diagnostics.Process')
if (Test-Path (Join-Path $PSHOME 'System.Private.Windows.GdiPlus.dll')) { $nativeReferences += 'System.Private.Windows.GdiPlus' }
Add-Type -ReferencedAssemblies $nativeReferences -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public static class CompositionNative {
    sealed class BackdropWindow : Form {
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams {
            get { var p=base.CreateParams;p.ExStyle|=0x08000000;return p; }
        }
    }

    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int X,Y,R,B; public int Width { get { return R-X; } } public int Height { get { return B-Y; } } }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X,Y; }
    [StructLayout(LayoutKind.Sequential)] struct GuiThreadInfo {
        public uint Size,Flags;public IntPtr Active,Focus,Capture,MenuOwner,MoveSize,Caret;public Rect CaretRect;
    }
    [StructLayout(LayoutKind.Sequential)] struct BitmapInfo {
        public uint Size; public int Width,Height; public ushort Planes,Bits;
        public uint Compression,ImageSize; public int XPels,YPels; public uint Used,Important,Color;
    }
    delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll",SetLastError=true)] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h,EnumProc cb,IntPtr p);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder name,int count);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
    [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h,int index);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint thread,ref GuiThreadInfo info);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h,out Rect r);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h,out Rect r);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h,ref Point p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h,uint flags);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point p);
    [DllImport("user32.dll",EntryPoint="PostMessageW",SetLastError=true)] static extern bool PostMessageNative(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll",EntryPoint="SetWindowPos",SetLastError=true)] static extern bool SetWindowPosNative(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags);
    [DllImport("user32.dll",EntryPoint="ShowWindow")] static extern bool ShowWindowNative(IntPtr h,int command);
    static readonly HashSet<uint> ownedProcesses=new HashSet<uint>{(uint)System.Diagnostics.Process.GetCurrentProcess().Id};
    public static void RegisterProcess(int pid){ownedProcesses.Add((uint)pid);}
    public static void UnregisterProcess(int pid){ownedProcesses.Remove((uint)pid);}
    static void RequireOwned(IntPtr h){uint pid;if(h==IntPtr.Zero||GetWindowThreadProcessId(h,out pid)==0||!ownedProcesses.Contains(pid))throw new Exception("Refusing a window not owned by the composition test");}
    public static bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l){RequireOwned(h);return PostMessageNative(h,m,w,l);}
    public static bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags){RequireOwned(h);if(after.ToInt64()>1)RequireOwned(after);return SetWindowPosNative(h,after,x,y,w,height,flags);}
    public static bool ShowWindow(IntPtr h,int command){RequireOwned(h);return ShowWindowNative(h,command);}
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h,IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc,ref BitmapInfo info,uint usage,out IntPtr bits,IntPtr section,uint offset);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc,IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr dst,int x,int y,int w,int h,IntPtr src,int sx,int sy,uint rop);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("dwmapi.dll")] public static extern int DwmFlush();
    static Form backdrop; static Thread thread; static int pattern; static Exception startupError;
    public static IntPtr Backdrop;
    public static Rect BackdropRect;
    public static void StartBackdrop() {
        SetProcessDpiAwarenessContext(new IntPtr(-4)); SetThreadDpiAwarenessContext(new IntPtr(-4));
        var ready=new ManualResetEvent(false);
        thread=new Thread(()=> {
            try {
                SetThreadDpiAwarenessContext(new IntPtr(-4));
                backdrop=new BackdropWindow { Text="Ghostty composition backdrop",FormBorderStyle=FormBorderStyle.None,ShowInTaskbar=false,TopMost=true,StartPosition=FormStartPosition.Manual };
                backdrop.Paint+=(s,e)=> {
                    var r=backdrop.ClientRectangle;
                    using(var gray=new SolidBrush(Color.FromArgb(128,128,128))) e.Graphics.FillRectangle(gray,r);
                    e.Graphics.FillRectangle(Brushes.White,r.Width/2,0,r.Width-r.Width/2,r.Height);
                    if(pattern==1) {
                        for(int x=0;x<r.Width;x+=8) e.Graphics.FillRectangle((x/8)%2==0?Brushes.Black:Brushes.White,x,0,8,r.Height/2);
                        for(int x=0;x<r.Width;x+=128) e.Graphics.FillRectangle((x/128)%2==0?Brushes.Black:Brushes.White,x,r.Height/2,128,r.Height);
                    }
                    if(pattern==2)e.Graphics.FillRectangle(Brushes.Black,r);
                };
                backdrop.Shown+=(s,e)=> {Backdrop=backdrop.Handle;ready.Set();};
                Application.Run(backdrop);
            } catch(Exception e) {startupError=e;ready.Set();}
        });
        thread.SetApartmentState(ApartmentState.STA);thread.IsBackground=true;thread.Start();
        if(!ready.WaitOne(10000)) throw new Exception("Backdrop UI thread did not start");
        if(startupError!=null) throw startupError;
        ready.Dispose();
    }
    public static void StopBackdrop() {
        if(backdrop!=null && !backdrop.IsDisposed) backdrop.BeginInvoke(new Action(()=>backdrop.Close()));
        if(thread!=null && !thread.Join(5000)) throw new Exception("Backdrop UI thread did not stop");
    }
    public static void PlaceBackdrop(IntPtr top,int mode) {
        var r=WindowRect(top);pattern=mode;
        RequireOwned(top);RequireOwned(Backdrop);
        // Keep the app's real ownership tree; the cross-process scene uses explicit z-order.
        backdrop.Invoke(new Action(()=> {backdrop.Bounds=new Rectangle(r.X-16,r.Y-16,r.Width+64,r.Height+64);backdrop.Invalidate();backdrop.Update();}));
        if(!SetWindowPos(Backdrop,new IntPtr(-1),r.X-16,r.Y-16,r.Width+64,r.Height+64,0x10|0x40)) throw new Exception("Positioning backdrop failed");
        if(!SetWindowPos(top,new IntPtr(-1),0,0,0,0,0x253)) throw new Exception("Placing owned terminal above backdrop failed");
        BackdropRect=ClientRect(Backdrop);
    }
    public class TabTransitionFrame { public int Switch,Frame;public double Milliseconds,MaxError;public double[] Mean; }
    public class TabTransitionResult { public double MaxError;public List<TabTransitionFrame> Frames=new List<TabTransitionFrame>(); }
    public static TabTransitionResult TraceTabTransitions(IntPtr top,Rect roi,int switches,string output,string name) {
        var result=new TabTransitionResult();uint pid;GetWindowThreadProcessId(top,out pid);
        double[] reference;using(var b=Capture(roi))reference=Mean(b,roi,roi);
        for(int turn=0;turn<switches;turn++) {
            var children=Windows((int)pid,"GhosttyTerminal",top,true);
            if(children.Length!=1)throw new Exception("Expected one visible terminal before tab switch");
            IntPtr previous=children[0];
            if(!PostMessage(previous,0x100,new IntPtr(0x73),new IntPtr(1))||
               !PostMessage(previous,0x101,new IntPtr(0x73),new IntPtr(unchecked((int)0xC0000001))))
                throw new Exception("Posting tab switch failed");
            var watch=System.Diagnostics.Stopwatch.StartNew();
            for(int frame=0;frame<10;frame++) {
                if(DwmFlush()<0)throw new Exception("DwmFlush failed");
                Owns(roi,top);
                using(var b=Capture(roi)) {
                    var mean=Mean(b,roi,roi);double error=0;
                    for(int channel=0;channel<3;channel++)error=Math.Max(error,Math.Abs(mean[channel]-reference[channel]));
                    result.MaxError=Math.Max(result.MaxError,error);
                    result.Frames.Add(new TabTransitionFrame{Switch=turn,Frame=frame,Milliseconds=watch.Elapsed.TotalMilliseconds,Mean=mean,MaxError=error});
                    if(error>3)b.Save(System.IO.Path.Combine(output,name+"-transient-"+turn+"-"+frame+".png"),ImageFormat.Png);
                }
                Owns(roi,top);
            }
            children=Windows((int)pid,"GhosttyTerminal",top,true);
            if(children.Length!=1||children[0]==previous)throw new Exception("Tab switch did not activate the other terminal");
        }
        return result;
    }
    public class TabCreationFrame { public int Frame,VisibleChildren;public long FocusedChild;public double Milliseconds,MaxError;public double[] Errors; }
    public class TabCreationResult { public Rect[] Rois;public double MaxError;public bool TypedBeforeReveal;public List<TabCreationFrame> Frames=new List<TabCreationFrame>(); }
    public static TabCreationResult TraceTabCreation(IntPtr top,string output,string name) {
        var client=ClientRect(top);uint pid;uint guiThread=GetWindowThreadProcessId(top,out pid);
        var children=Windows((int)pid,"GhosttyTerminal",top,true);
        if(children.Length!=1)throw new Exception("Expected one initial terminal");
        IntPtr previous=children[0];int bar=ClientRect(previous).Y-client.Y;
        var regions=new List<Rect>{Roi(client.X+2,client.B-14,12,12),Roi(client.R-30,client.B-14,12,12),Roi(client.X+client.Width/5,client.Y+client.Height*7/10,12,12),Roi(client.X+client.Width/2,client.Y+client.Height*7/10,12,12),Roi(client.X+client.Width*4/5,client.Y+client.Height*7/10,12,12),Roi(client.X+client.Width*4/5,client.Y+Math.Max(bar,50)+2,12,12)};
        if(bar>0)regions.Add(Roi(client.R-18,client.Y+2,12,2));
        var result=new TabCreationResult{Rois=regions.ToArray()};var reference=new double[regions.Count][];
        using(var b=Capture(client)){for(int i=0;i<regions.Count;i++)reference[i]=Mean(b,client,regions[i]);}
        if(!PostMessage(previous,0x100,new IntPtr(0x70),new IntPtr(1))||
           !PostMessage(previous,0x101,new IntPtr(0x70),new IntPtr(unchecked((int)0xC0000001))))
            throw new Exception("Posting owned new-tab key failed");
        var watch=System.Diagnostics.Stopwatch.StartNew();bool typed=false;int revealedFrames=0;
        for(int frame=0;frame<80||revealedFrames<10;frame++) {
            if(watch.ElapsedMilliseconds>20000)throw new Exception("New tab did not become active within 20 seconds; samples="+frame+", visible="+children.Length);
            if(DwmFlush()<0)throw new Exception("DwmFlush failed");
            foreach(var roi in regions)Owns(roi,top);
            using(var b=Capture(client)) {
                double error=0;var errors=new double[regions.Count];
                for(int i=0;i<regions.Count;i++){var mean=Mean(b,client,regions[i]);for(int channel=0;channel<3;channel++)errors[i]=Math.Max(errors[i],Math.Abs(mean[channel]-reference[i][channel]));error=Math.Max(error,errors[i]);}
                children=Windows((int)pid,"GhosttyTerminal",top,true);
                var gui=new GuiThreadInfo{Size=(uint)Marshal.SizeOf(typeof(GuiThreadInfo))};
                if(!GetGUIThreadInfo(guiThread,ref gui))throw new Exception("Reading owned keyboard focus failed");
                if(!typed&&gui.Focus!=previous&&Array.IndexOf(Windows((int)pid,"GhosttyTerminal",top,false),gui.Focus)>=0) {
                    if(!PostMessage(gui.Focus,0x100,new IntPtr(0x58),new IntPtr(1))||
                       !PostMessage(gui.Focus,0x102,new IntPtr('x'),new IntPtr(1))||
                       !PostMessage(gui.Focus,0x101,new IntPtr(0x58),new IntPtr(unchecked((int)0xC0000001))))
                        throw new Exception("Posting owned terminal typing failed");
                    typed=true;result.TypedBeforeReveal=children.Length==1&&children[0]==previous;
                }
                result.MaxError=Math.Max(result.MaxError,error);result.Frames.Add(new TabCreationFrame{Frame=frame,Milliseconds=watch.Elapsed.TotalMilliseconds,MaxError=error,Errors=errors,VisibleChildren=children.Length,FocusedChild=gui.Focus.ToInt64()});
                revealedFrames=children.Length==1&&children[0]!=previous?revealedFrames+1:0;
                if(error>3)b.Save(System.IO.Path.Combine(output,name+"-frame-"+frame.ToString("D3")+".png"),ImageFormat.Png);
            }
            foreach(var roi in regions)Owns(roi,top);
        }
        children=Windows((int)pid,"GhosttyTerminal",top,true);
        if(children.Length!=1||children[0]==previous)throw new Exception("New tab did not become active");
        if(!typed)throw new Exception("Keyboard focus never reached the new terminal");
        return result;
    }
    public static IntPtr[] Windows(int pid,string cls,IntPtr parent,bool visible) {
        var result=new List<IntPtr>();
        EnumProc cb=(h,p)=> {uint id;GetWindowThreadProcessId(h,out id);var name=new StringBuilder(128);GetClassName(h,name,128);bool live=cls!="GhosttyTerminal"||GetWindowLongPtr(h,-21)!=IntPtr.Zero;if(id==(uint)pid&&live&&name.ToString()==cls&&(!visible||IsWindowVisible(h)))result.Add(h);return true;};
        if(parent==IntPtr.Zero)EnumWindows(cb,IntPtr.Zero);else EnumChildWindows(parent,cb,IntPtr.Zero);
        return result.ToArray();
    }
    public static Rect WindowRect(IntPtr h) {Rect r;if(!GetWindowRect(h,out r))throw new Exception("GetWindowRect failed");return r;}
    public static Rect ClientRect(IntPtr h) {
        Rect r;if(!GetClientRect(h,out r))throw new Exception("GetClientRect failed");
        var a=new Point{X=r.X,Y=r.Y};var b=new Point{X=r.R,Y=r.B};
        if(!ClientToScreen(h,ref a)||!ClientToScreen(h,ref b))throw new Exception("ClientToScreen failed");
        return new Rect{X=a.X,Y=a.Y,R=b.X,B=b.Y};
    }
    public static Rect Roi(int x,int y,int w,int h) {return new Rect{X=x,Y=y,R=x+w,B=y+h};}
    public static void Owns(Rect r,IntPtr expected) {
        for(int y=r.Y;y<r.B;y+=4) for(int x=r.X;x<r.R;x+=4) {
            var h=WindowFromPoint(new Point{X=x,Y=y});
            var root=GetAncestor(h,2);uint rootPid,expectedPid;
            GetWindowThreadProcessId(root,out rootPid);GetWindowThreadProcessId(expected,out expectedPid);
            bool ownedPopup=rootPid==expectedPid&&GetWindowLongPtr(root,-8)==expected;
            if(h==IntPtr.Zero||(root!=expected&&!ownedPopup))throw new Exception("Invalid capture: owner "+root+" expected "+expected+" at "+x+","+y);
        }
    }
    public static Bitmap Capture(Rect r) {
        if(r.Width<=0||r.Height<=0)throw new Exception("Invalid capture dimensions");
        IntPtr screen=GetDC(IntPtr.Zero),dc=IntPtr.Zero,dib=IntPtr.Zero,old=IntPtr.Zero,bits;
        try {
            if(screen==IntPtr.Zero)throw new Exception("Desktop DC unavailable");
            dc=CreateCompatibleDC(screen);if(dc==IntPtr.Zero)throw new Exception("CreateCompatibleDC failed");
            var info=new BitmapInfo {Size=40,Width=r.Width,Height=-r.Height,Planes=1,Bits=32};
            dib=CreateDIBSection(screen,ref info,0,out bits,IntPtr.Zero,0);if(dib==IntPtr.Zero)throw new Exception("CreateDIBSection failed");
            old=SelectObject(dc,dib);
            if(!BitBlt(dc,0,0,r.Width,r.Height,screen,r.X,r.Y,0x00CC0020|0x40000000))throw new Exception("Desktop BitBlt failed");
            var bytes=new byte[r.Width*r.Height*4];Marshal.Copy(bits,bytes,0,bytes.Length);
            for(int i=3;i<bytes.Length;i+=4)bytes[i]=255;
            var result=new Bitmap(r.Width,r.Height,PixelFormat.Format32bppArgb);
            var locked=result.LockBits(new Rectangle(0,0,r.Width,r.Height),ImageLockMode.WriteOnly,PixelFormat.Format32bppArgb);
            try {Marshal.Copy(bytes,0,locked.Scan0,bytes.Length);} finally {result.UnlockBits(locked);}
            return result;
        } finally {
            if(old!=IntPtr.Zero)SelectObject(dc,old);if(dib!=IntPtr.Zero)DeleteObject(dib);if(dc!=IntPtr.Zero)DeleteDC(dc);if(screen!=IntPtr.Zero)ReleaseDC(IntPtr.Zero,screen);
        }
    }
    public static int BackdropValue(int screenX,int screenY) {
        int x=screenX-BackdropRect.X,y=screenY-BackdropRect.Y;
        if(pattern==2)return 0;
        if(pattern==1)return (y<BackdropRect.Height/2?x/8:x/128)%2==0?0:255;
        return x<BackdropRect.Width/2?128:255;
    }
    public static double[] Mean(Bitmap b,Rect capture,Rect roi) {
        var v=new double[3];int n=0;
        for(int y=roi.Y;y<roi.B;y++)for(int x=roi.X;x<roi.R;x++){var c=b.GetPixel(x-capture.X,y-capture.Y);v[0]+=c.R;v[1]+=c.G;v[2]+=c.B;n++;}
        for(int i=0;i<3;i++)v[i]/=n;return v;
    }
    public static double BackgroundError(Bitmap b,Rect capture,Rect roi,double opacity) {
        double a=Math.Round(255*opacity,MidpointRounding.AwayFromZero)/255,max=0;
        int[] color={30,30,46};
        for(int y=roi.Y;y<roi.B;y++)for(int x=roi.X;x<roi.R;x++) {
            var c=b.GetPixel(x-capture.X,y-capture.Y);int[] actual={c.R,c.G,c.B};int bg=BackdropValue(x,y);
            for(int i=0;i<3;i++)max=Math.Max(max,Math.Abs(actual[i]-(a*color[i]+(1-a)*bg)));
        }
        return max;
    }
    public static Rect FindColor(Bitmap b,Rect capture,Rect search,int red,int green,int blue) {
        int l=search.R,t=search.B,r=search.X,bot=search.Y;
        for(int y=search.Y;y<search.B;y++)for(int x=search.X;x<search.R;x++) {
            var c=b.GetPixel(x-capture.X,y-capture.Y);
            if(Math.Abs(c.R-red)<=2&&Math.Abs(c.G-green)<=2&&Math.Abs(c.B-blue)<=2){l=Math.Min(l,x);t=Math.Min(t,y);r=Math.Max(r,x+1);bot=Math.Max(bot,y+1);}
        }
        if(r-l<4||bot-t<4)throw new Exception("Opaque reference marker missing: "+red+","+green+","+blue);
        return Roi(l+2,t+2,r-l-4,bot-t-4);
    }
    public static int CountColor(Bitmap b,Rect capture,Rect search,int red,int green,int blue) {
        int count=0;
        for(int y=search.Y;y<search.B;y++)for(int x=search.X;x<search.R;x++){
            var c=b.GetPixel(x-capture.X,y-capture.Y);
            if(Math.Abs(c.R-red)<=2&&Math.Abs(c.G-green)<=2&&Math.Abs(c.B-blue)<=2)count++;
        }
        return count;
    }
    static double Luminance(Color c) {return .2126*c.R+.7152*c.G+.0722*c.B;}
    public static double StripeContrast(Bitmap b,Rect capture,Rect roi) {
        double sum=0;int n=0;
        for(int y=roi.Y;y<roi.B;y++)for(int x=roi.X+1;x<roi.R;x++){sum+=Math.Abs(Luminance(b.GetPixel(x-capture.X,y-capture.Y))-Luminance(b.GetPixel(x-1-capture.X,y-capture.Y)));n++;}
        return sum/n;
    }
    public static int MaxDifference(Bitmap a,Rect ar,Bitmap b,Rect br,Rect roi) {
        int error=0;
        for(int y=roi.Y;y<roi.B;y++)for(int x=roi.X;x<roi.R;x++){
            var p=a.GetPixel(x-ar.X,y-ar.Y);var q=b.GetPixel(x-br.X,y-br.Y);
            error=Math.Max(error,Math.Max(Math.Abs(p.R-q.R),Math.Max(Math.Abs(p.G-q.G),Math.Abs(p.B-q.B))));
        }
        return error;
    }
    public static int MonitorCount {get{return Screen.AllScreens.Length;}}
    public static Rectangle[] MonitorAreas {get{var screens=Screen.AllScreens;var areas=new Rectangle[screens.Length];for(int i=0;i<screens.Length;i++)areas[i]=screens[i].WorkingArea;return areas;}}
    public static Rectangle WorkArea {get{return Screen.PrimaryScreen.WorkingArea;}}
}
'@

$work = Join-Path $env:TEMP ('ghostty-composition-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
$script:runs = [Collections.Generic.List[object]]::new()
$script:counter = 0
$script:patternMode = 0
$script:record = [ordered]@{ Case=$Case; Started=(Get-Date).ToString('o'); Status='failed'; Captures=@(); Assertions=@(); Unavailable=@(); Errors=@(); Policy=@{} }
$script:reference = $null
$script:backdropStarted = $false
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$pattern = Join-Path $work 'pattern.ps1'
@'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
function Draw-Pattern {
    [Console]::Write("`e[0m`e[2J`e[H`e[38;2;0;255;0m███`e[0m")
    foreach($row in 2..4){[Console]::Write("`e[$row;3H`e[38;2;255;255;255m██████████`e[0m")}
    foreach($row in 6..8){[Console]::Write("`e[$row;3H`e[48;2;255;0;0m          `e[0m")}
    [Console]::Write("`e[10;3H`e[38;2;40;200;120mcolored text`e[0m`e[18;1H`e[38;2;0;0;255m███`e[0m`e[10;30H`e[?25h")
    if($inputCount -gt 0){[Console]::Write("`e[12;3H`e[38;2;255;255;0mtyped input $inputCount`e[0m`e[10;30H")}
}
$inputCount=0
Draw-Pattern
$width=[Console]::WindowWidth;$height=[Console]::WindowHeight
while($true){
    if([Console]::KeyAvailable){$key=[Console]::ReadKey($true);if($key.KeyChar -eq 'q'){break};$inputCount++;if($key.KeyChar -eq 's'){[Console]::Write("`e[25;1H"+('scroll proof'+"`r`n")*40)};Draw-Pattern}
    if($width -ne [Console]::WindowWidth -or $height -ne [Console]::WindowHeight){$width=[Console]::WindowWidth;$height=[Console]::WindowHeight;Draw-Pattern}
    Start-Sleep -Milliseconds 100
}
'@ | Set-Content -Encoding utf8 $pattern

function Assert-Proof([bool]$Condition,[string]$Name,$Metrics) {
    $script:record.Assertions += @{Name=$Name;Passed=$Condition;Metrics=$Metrics}
    if(-not $Condition){throw "Composition assertion failed: $Name"}
}
function Set-Config($Run,[hashtable]$Values) {
    foreach($entry in $Values.GetEnumerator()){$Run.Values[$entry.Key]=$entry.Value}
    $Run.Values.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key) = $($_.Value)" } | Set-Content -Encoding utf8 $Run.Config
}
function Send-Key([IntPtr]$Child,[int]$Key,[int]$SettleMilliseconds=700) {
    if(-not [CompositionNative]::PostMessage($Child,0x100,[IntPtr]$Key,[IntPtr]1)){throw 'Posting keydown failed'}
    if($SettleMilliseconds -gt 0){Start-Sleep -Milliseconds 50}
    if(-not [CompositionNative]::PostMessage($Child,0x101,[IntPtr]$Key,[IntPtr]0xC0000001)){throw 'Posting keyup failed'}
    if($SettleMilliseconds -gt 0){Start-Sleep -Milliseconds $SettleMilliseconds}
}
function Get-Tops($Run) { return @([CompositionNative]::Windows($Run.Process.Id,'GhosttyWindow',[IntPtr]::Zero,$true)) }
function Get-Children($Run,[IntPtr]$Top) { return @([CompositionNative]::Windows($Run.Process.Id,'GhosttyTerminal',$Top,$true)) }
function Start-Ghostty([double]$Opacity=0.5,[string]$Blend='native',[hashtable]$Values=@{}) {
    $run=@{ Config=(Join-Path $work ([guid]::NewGuid().ToString('N')+'.ghostty')); Values=@{
        'background'='#1e1e2e';'foreground'='#ffffff';'font-family'='Consolas';'font-size'='14';
        'background-opacity'=$Opacity.ToString([Globalization.CultureInfo]::InvariantCulture);'background-opacity-cells'='false';'background-blur'='false';'alpha-blending'=$Blend;
        'unfocused-split-opacity'='1';'shell-integration'='none';'confirm-close-surface'='false';'window-padding-x'='0';'window-padding-y'='0';'window-padding-balance'='false';
        'cursor-style'='block';'cursor-style-blink'='false';'cursor-color'='#ffffff';'quick-terminal-animation-duration'='0';
        'quick-terminal-position'='center';'quick-terminal-size'='650px,900px';
        'resize-overlay'='never';'auto-update'='off';
        'command'=('pwsh.exe -NoLogo -NoProfile -File "'+$pattern+'"');
        'keybind'="f12=reload_config`nkeybind = f11=toggle_background_opacity`nkeybind = f1=new_tab`nkeybind = f2=new_split:right`nkeybind = f3=new_window`nkeybind = f4=next_tab`nkeybind = f5=toggle_split_zoom`nkeybind = f6=move_tab_to_new_window`nkeybind = f7=toggle_quick_terminal"
    }}
    Set-Config $run $Values
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=[IO.Path]::GetFullPath($ExePath);$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.Environment['GHOSTTY_RESOURCES_DIR']=[IO.Path]::GetFullPath($ResourcesPath)
    $psi.ArgumentList.Add('--config-default-files=false');$psi.ArgumentList.Add('--config-file='+$run.Config)
    $run.Process=[Diagnostics.Process]::Start($psi);$script:runs.Add($run)
    [CompositionNative]::RegisterProcess($run.Process.Id)
    $run.Stdout=$run.Process.StandardOutput.ReadToEndAsync();$run.Stderr=$run.Process.StandardError.ReadToEndAsync()
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    do {
        if($run.Process.HasExited){throw "Ghostty exited: $($run.Stderr.GetAwaiter().GetResult())"}
        $tops=Get-Tops $run
        if($tops.Count){$children=Get-Children $run $tops[0];if($children.Count){$run.Top=$tops[0];$run.Child=$children[0];break}}
        Start-Sleep -Milliseconds 100
    } while([DateTime]::UtcNow -lt $deadline)
    if(-not $run.Child){throw 'PID-scoped Ghostty terminal not found'}
    $area=[CompositionNative]::WorkArea
    $run.Width=[Math]::Min(900,$area.Width-100);$run.Height=[Math]::Min(680,$area.Height-100)
    [CompositionNative]::SetWindowPos($run.Top,[IntPtr]::Zero,$area.X+30,$area.Y+30,$run.Width,$run.Height,0x50) | Out-Null
    Start-Sleep -Seconds 2
    $children=Get-Children $run $run.Top
    if($children.Count -ne 1){throw 'Expected one live terminal after startup recovery'}
    $run.Child=$children[0]
    return $run
}
function Stop-Ghostty($Run) {
    if(-not $Run.Process.HasExited){
        foreach($top in [CompositionNative]::Windows($Run.Process.Id,'GhosttyWindow',[IntPtr]::Zero,$false)){
            foreach($child in [CompositionNative]::Windows($Run.Process.Id,'GhosttyTerminal',$top,$false)){
                Send-Key $child 0x51 0
            }
        }
        if(-not $Run.Process.WaitForExit(3000)){
            foreach($top in (Get-Tops $Run)){[CompositionNative]::PostMessage($top,0x10,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null}
            if(-not $Run.Process.WaitForExit(5000)){$Run.Process.Kill($true);$Run.Process.WaitForExit()}
        }
    }
    [CompositionNative]::UnregisterProcess($Run.Process.Id)
    [IO.File]::WriteAllText((Join-Path $OutputDirectory "ghostty-$($Run.Process.Id).stdout.log"),$Run.Stdout.GetAwaiter().GetResult())
    [IO.File]::WriteAllText((Join-Path $OutputDirectory "ghostty-$($Run.Process.Id).stderr.log"),$Run.Stderr.GetAwaiter().GetResult())
}
function Check-BackdropStrip($Strip) {
    if([CompositionNative]::DwmFlush() -lt 0){throw 'DwmFlush failed'}
    $sample=[CompositionNative]::Capture($Strip)
    try {
        $error=[CompositionNative]::BackgroundError($sample,$Strip,$Strip,0)
        if($error -gt 3){throw "Invalid capture: exposed backdrop mismatch $error"}
        return $error
    } finally {$sample.Dispose()}
}
function Capture-Proof($Run,[string]$Name,[IntPtr]$Top=$Run.Top,[IntPtr]$Child=$Run.Child) {
    $script:counter++
    [CompositionNative]::PlaceBackdrop($Top,$script:patternMode)
    Start-Sleep -Milliseconds 500
    $client=[CompositionNative]::ClientRect($Child);$capture=[CompositionNative]::ClientRect([CompositionNative]::Backdrop)
    $strip=[CompositionNative]::Roi($capture.R-12,$capture.Y+30,8,[Math]::Min(128,$capture.Height-60))
    $rois=@{
        gray=[CompositionNative]::Roi($client.X+[int]($client.Width*.38),$client.Y+[int]($client.Height*.65),12,12)
        white=[CompositionNative]::Roi($client.X+[int]($client.Width*.78),$client.Y+[int]($client.Height*.65),12,12)
    }
    $meta=@{Name=$Name;Pid=$Run.Process.Id;Hwnd=$Top.ToInt64();TerminalHwnd=$Child.ToInt64();BackdropHwnd=[CompositionNative]::Backdrop.ToInt64();Client=$client;Capture=$capture;Rois=$rois;Strip=$strip;Config=(Get-Content -Raw $Run.Config);Valid=$false;Error=$null}
    $path=Join-Path $OutputDirectory ('{0:D3}-{1}' -f $script:counter,$Name)
    $bitmap=$null
    try {
        $meta.ForegroundBefore=[CompositionNative]::GetForegroundWindow().ToInt64()
        if([CompositionNative]::DwmFlush() -lt 0){throw 'DwmFlush failed'}
        [CompositionNative]::Owns($client,$Top);[CompositionNative]::Owns($strip,[CompositionNative]::Backdrop)
        $meta.StripErrorBefore=Check-BackdropStrip $strip
        $bitmap=[CompositionNative]::Capture($capture)
        $bitmap.Save($path+'.png',[Drawing.Imaging.ImageFormat]::Png)
        [CompositionNative]::Owns($client,$Top);[CompositionNative]::Owns($strip,[CompositionNative]::Backdrop)
        $meta.StripErrorAfter=Check-BackdropStrip $strip
        $meta.ForegroundAfter=[CompositionNative]::GetForegroundWindow().ToInt64()
        if($meta.ForegroundBefore -ne $meta.ForegroundAfter){throw 'Invalid capture: foreground changed during capture'}
        $stripError=[CompositionNative]::BackgroundError($bitmap,$capture,$strip,0)
        if($stripError -gt 3){throw "Invalid capture: exposed backdrop mismatch $stripError"}
        $meta.Valid=$true;$meta.StripError=$stripError
        return @{Bitmap=$bitmap;Rect=$capture;Client=$client;Rois=$rois;Top=$Top;Child=$Child;Meta=$meta}
    } catch {
        $meta.Error=$_.Exception.Message
        if(-not $bitmap){try{$bitmap=[CompositionNative]::Capture($capture);$bitmap.Save($path+'.png',[Drawing.Imaging.ImageFormat]::Png)}catch{}}
        if($bitmap){$bitmap.Dispose()}
        throw
    } finally {
        $meta | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8 ($path+'.json')
        $script:record.Captures+=$meta
    }
}
function Assert-Background($Shot,[double]$Opacity,[string]$Name) {
    foreach($key in @('gray','white')){
        $roi=$Shot.Rois[$key];$error=[CompositionNative]::BackgroundError($Shot.Bitmap,$Shot.Rect,$roi,$Opacity)
        Assert-Proof ($error -le 3) "$Name background $key" @{Opacity=$Opacity;MaxChannelError=$error;Roi=$roi;Mean=[CompositionNative]::Mean($Shot.Bitmap,$Shot.Rect,$roi)}
    }
}
function Get-Markers($Shot) {
    $c=$Shot.Client;$search=[CompositionNative]::Roi($c.X,$c.Y,[int]($c.Width*.32),[int]($c.Height*.92))
    $markers=@{}
    foreach($item in @(@('glyph',255,255,255),@('cell',255,0,0),@('top',0,255,0),@('bottom',0,0,255))){
        $r=[CompositionNative]::FindColor($Shot.Bitmap,$Shot.Rect,$search,$item[1],$item[2],$item[3])
        $markers[$item[0]]=@{X=$r.X-$c.X;Y=$r.Y-$c.Y;Width=$r.Width;Height=$r.Height;Color=@($item[1],$item[2],$item[3])}
    }
    Assert-Proof ($markers.top.Y -lt $markers.glyph.Y -and $markers.glyph.Y -lt $markers.cell.Y -and $markers.cell.Y -lt $markers.bottom.Y) 'Asymmetric markers retain vertical orientation and RGB order' $markers
    $cw=($markers.glyph.Width+4)/10;$ch=($markers.glyph.Height+4)/3
    $markers.cursor=@{X=[int](29*$cw);Y=[int](9*$ch);Width=[int]$cw;Height=[int]$ch;Color=@(255,255,255)}
    return $markers
}
function Assert-Foreground($Shot,$Markers,[string]$Name,[bool]$Cells=$false) {
    foreach($key in $Markers.Keys){
        if($Cells -and $key -eq 'cell'){continue}
        $m=$Markers[$key];$roi=[CompositionNative]::Roi($Shot.Client.X+$m.X,$Shot.Client.Y+$m.Y,$m.Width,$m.Height)
        if($key -eq 'cursor'){
            $opaquePixels=[CompositionNative]::CountColor($Shot.Bitmap,$Shot.Rect,$roi,255,255,255)
            Assert-Proof ($opaquePixels -gt 0) "$Name opaque cursor strokes" @{OpaqueWhitePixels=$opaquePixels;Roi=$roi;ExpectedColor=@(255,255,255)}
            continue
        }
        $mean=[CompositionNative]::Mean($Shot.Bitmap,$Shot.Rect,$roi);$error=0.0
        for($i=0;$i -lt 3;$i++){$error=[Math]::Max($error,[Math]::Abs($mean[$i]-$m.Color[$i]))}
        Assert-Proof ($error -le 3) "$Name opaque $key" @{MaxChannelError=$error;Roi=$roi;Mean=$mean}
    }
}
function Check-Frame($Run,[string]$Name,[double]$Opacity,$Markers=$script:reference,[IntPtr]$Top=$Run.Top,[IntPtr]$Child=$Run.Child) {
    $s=Capture-Proof $Run $Name $Top $Child
    try {Assert-Background $s $Opacity $Name;if($Markers){Assert-Foreground $s $Markers $Name}} finally {$s.Bitmap.Dispose()}
}
function Reload($Run,[hashtable]$Values,[IntPtr]$Child=$Run.Child) {Set-Config $Run $Values;Send-Key $Child 0x7B}
function Check-ChromeOpacity($Run,[string]$Name,[double]$Opacity,[int[]]$Ink=@(255,255,255)) {
    $shot=Capture-Proof $Run $Name
    try {
        $client=[CompositionNative]::ClientRect($Run.Top)
        $barHeight=$shot.Client.Y-$client.Y
        Assert-Proof ($barHeight -ge 20) "$Name exposes the tab strip" @{Height=$barHeight}
        $left=[CompositionNative]::Roi($client.X+[int]($client.Width*.38),$client.Y+2,12,2)
        $right=[CompositionNative]::Roi($client.X+[int]($client.Width*.78),$client.Y+2,12,2)
        [CompositionNative]::Owns($left,$Run.Top);[CompositionNative]::Owns($right,$Run.Top)
        $a=[CompositionNative]::Mean($shot.Bitmap,$shot.Rect,$left)
        $b=[CompositionNative]::Mean($shot.Bitmap,$shot.Rect,$right)
        $expected=127*(1-[Math]::Round(255*$Opacity,[MidpointRounding]::AwayFromZero)/255)
        $error=0.0
        for($i=0;$i -lt 3;$i++){$error=[Math]::Max($error,[Math]::Abs(($b[$i]-$a[$i])-$expected))}
        Assert-Proof ($error -le 3) "$Name tab background follows effective opacity" @{Opacity=$Opacity;MaxChannelError=$error;Gray=$a;White=$b;ExpectedContrast=$expected}
        $label=[CompositionNative]::Roi($client.X+[int]($client.Width*.3),$client.Y+4,[int]($client.Width*.4),$barHeight-8)
        $inkPixels=[CompositionNative]::CountColor($shot.Bitmap,$shot.Rect,$label,$Ink[0],$Ink[1],$Ink[2])
        Assert-Proof ($inkPixels -gt 0) "$Name keeps tab label ink opaque" @{OpaquePixels=$inkPixels;Roi=$label;Color=$Ink}
    } finally {$shot.Bitmap.Dispose()}
}
function Check-TabTransitions($Run,[string]$Name) {
    $s=Capture-Proof $Run ($Name+'-before')
    try {
        $roi=[CompositionNative]::Roi($s.Client.X+[int]($s.Client.Width*.38),$s.Client.Y+[int]($s.Client.Height*.65),12,12)
        $trace=[CompositionNative]::TraceTabTransitions($Run.Top,$roi,12,$OutputDirectory,$Name)
        Assert-Proof ($trace.MaxError -le 3) "$Name retains composed background during switches" @{MaxChannelError=$trace.MaxError;Roi=$roi;Frames=$trace.Frames}
    } finally {$s.Bitmap.Dispose()}
    $Run.Child=(Get-Children $Run $Run.Top)[0]
}
function Check-TabCreation($Run,[string]$Name) {
    $s=Capture-Proof $Run ($Name+'-before')
    try {
        $trace=[CompositionNative]::TraceTabCreation($Run.Top,$OutputDirectory,$Name)
        Assert-Proof ($trace.MaxError -le 3) "$Name preserves background while initializing a new tab" @{MaxChannelError=$trace.MaxError;Rois=$trace.Rois;Frames=$trace.Frames;TypedBeforeReveal=$trace.TypedBeforeReveal}
    } finally {$s.Bitmap.Dispose()}
    $Run.Child=(Get-Children $Run $Run.Top)[0]
    $s=Capture-Proof $Run ($Name+'-typed-new-tab')
    try {
        $typed=[CompositionNative]::FindColor($s.Bitmap,$s.Rect,$s.Client,255,255,0)
        Assert-Proof ([CompositionNative]::CountColor($s.Bitmap,$s.Rect,$typed,255,255,0) -gt 0) "$Name new tab receives owned-message typing" @{TypedRegion=$typed;BeforeReveal=$trace.TypedBeforeReveal}
    } finally {$s.Bitmap.Dispose()}
    Send-Key $Run.Child 0x73
    $Run.Child=(Get-Children $Run $Run.Top)[0]
    $s=Capture-Proof $Run ($Name+'-original-tab')
    try {
        $yellow=[CompositionNative]::CountColor($s.Bitmap,$s.Rect,$typed,255,255,0)
        Assert-Proof ($yellow -eq 0) "$Name original tab does not receive new-tab typing" @{UnexpectedTypedPixels=$yellow}
    } finally {$s.Bitmap.Dispose()}
}

try {
    if(-not (Test-Path $ExePath)){throw "Executable not found: $ExePath"}
    if(-not (Test-Path $ResourcesPath)){throw "Resources not found: $ResourcesPath"}
    $personalize=Get-ItemProperty 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Themes/Personalize' -ErrorAction SilentlyContinue
    $script:record.Policy=@{Build=[Environment]::OSVersion.Version.ToString();Interactive=[Environment]::UserInteractive;TransparencyEffects=$personalize.EnableTransparency;HighContrast=[Windows.Forms.SystemInformation]::HighContrast;PowerStatus=[Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus.ToString();PowerScheme=(& powercfg /getactivescheme | Out-String)}
    [CompositionNative]::StartBackdrop();$script:backdropStarted=$true
    $run=Start-Ghostty 1
    $s=Capture-Proof $run 'opaque-reference'
    try {
        $script:reference=Get-Markers $s
        Assert-Background $s 1 'opaque-reference';Assert-Foreground $s $script:reference 'opaque-reference'
        $script:opaqueBackground=[CompositionNative]::Mean($s.Bitmap,$s.Rect,$s.Rois.gray)
    } finally {$s.Bitmap.Dispose()}
    Stop-Ghostty $run
    if($Case -in @('opacity','all')){
        foreach($blend in @('native','linear','linear-corrected')){
            $values=if($blend -eq 'native'){@(0.5,0,0.01,0.25,0.75,0.96,0.99,1)}else{@(0,0.5,1)}
            foreach($a in $values){$run=Start-Ghostty $a $blend;Check-Frame $run "fresh-$blend-$a" $a;Stop-Ghostty $run}
        }
        $run=Start-Ghostty 0.5
        foreach($a in @(0.5,0.8,1,0,0.5)){Reload $run @{'background-opacity'=$a};Check-Frame $run "reload-$a" $a}
        Send-Key $run.Child 0x7A;Check-Frame $run 'toggle-opaque' 1
        Reload $run @{'background-opacity'=0.8};Check-Frame $run 'reload-while-forced' 1
        Send-Key $run.Child 0x7A;Check-Frame $run 'toggle-configured-0.8' 0.8
        foreach($blend in @('linear','linear-corrected','native')){Reload $run @{'alpha-blending'=$blend};Check-Frame $run "live-blending-$blend" 0.8}
        Reload $run @{'background-opacity'=0.5;'background-opacity-cells'='true'}
        $s=Capture-Proof $run 'cell-opacity-enabled'
        try {
            Assert-Background $s 0.5 'cell-opacity-enabled';Assert-Foreground $s $script:reference 'cell-opacity-enabled' $true
            $m=$script:reference.cell;$roi=[CompositionNative]::Roi($s.Client.X+$m.X,$s.Client.Y+$m.Y,$m.Width,$m.Height)
            $mean=[CompositionNative]::Mean($s.Bitmap,$s.Rect,$roi)
            Assert-Proof ($mean[1] -gt 3 -and $mean[0] -lt 252) 'Explicit cell background becomes translucent' @{Mean=$mean;Roi=$roi}
        } finally {$s.Bitmap.Dispose()}
        Stop-Ghostty $run
    }
    if($Case -in @('chrome','all')){
        $run=Start-Ghostty 0.5 'native' @{'window-show-tab-bar'='always';'window-theme'='dark'}
        Check-ChromeOpacity $run 'chrome-translucent' 0.5
        Send-Key $run.Child 0x7A;Check-ChromeOpacity $run 'chrome-forced-opaque' 1
        Reload $run @{'background-opacity'=0.8};Check-ChromeOpacity $run 'chrome-reload-while-forced' 1
        Send-Key $run.Child 0x7A;Check-ChromeOpacity $run 'chrome-restored-configured' 0.8
        Reload $run @{'background'='#ffffff';'foreground'='#1e1e2e';'window-theme'='light'}
        Check-ChromeOpacity $run 'chrome-light' 0.8 @(30,30,46)
        Reload $run @{'background'='#1e1e2e';'foreground'='#ffffff';'window-theme'='dark'}
        Reload $run @{'background-opacity'=0.5}
        $client=[CompositionNative]::ClientRect($run.Top)
        $terminal=[CompositionNative]::ClientRect($run.Child)
        $click=([int](($terminal.Y-$client.Y)/2) -shl 16) -bor [int]($client.Width/2)
        [CompositionNative]::PostMessage($run.Top,0x203,[IntPtr]1,[IntPtr]$click)|Out-Null
        Start-Sleep -Milliseconds 500
        $editors=@([CompositionNative]::Windows($run.Process.Id,'Edit',$run.Top,$true))
        Assert-Proof ($editors.Count -eq 1) 'Tab title editor opens over translucent strip' @{Editors=$editors.Count}
        $editShot=Capture-Proof $run 'chrome-title-editor'
        try {
            $editRect=[CompositionNative]::ClientRect($editors[0])
            $left=[CompositionNative]::Roi($editRect.X+[int]($editRect.Width*.38),$editRect.Y+3,12,2)
            $right=[CompositionNative]::Roi($editRect.X+[int]($editRect.Width*.78),$editRect.Y+3,12,2)
            $a=[CompositionNative]::Mean($editShot.Bitmap,$editShot.Rect,$left)
            $b=[CompositionNative]::Mean($editShot.Bitmap,$editShot.Rect,$right)
            $editorDifference=0.0;for($i=0;$i -lt 3;$i++){$editorDifference=[Math]::Max($editorDifference,[Math]::Abs($b[$i]-$a[$i]))}
            Assert-Proof ($editorDifference -le 1) 'Native title editor remains opaque over different backdrops' @{MaxChannelDifference=$editorDifference;Gray=$a;White=$b;Bounds=$editRect}
        } finally {$editShot.Bitmap.Dispose()}
        # Escape destroys the editor on keydown; do not send keyup to its retired HWND.
        [CompositionNative]::PostMessage($editors[0],0x100,[IntPtr]0x1B,[IntPtr]1)|Out-Null
        Start-Sleep -Milliseconds 500
        $remainingEditors=@([CompositionNative]::Windows($run.Process.Id,'Edit',$run.Top,$true))
        Assert-Proof ($remainingEditors.Count -eq 0) 'Escape closes the native title editor' @{Editors=$remainingEditors.Count}
        $script:patternMode=1
        $shots=@()
        foreach($state in @('false','true','false')){
            Reload $run @{'background-blur'=$state};$shots+=,(Capture-Proof $run "chrome-blur-$state-$($shots.Count)")
        }
        try {
            $client=[CompositionNative]::ClientRect($run.Top)
            $stripe=[CompositionNative]::Roi($client.X+[int]($client.Width*.4),$client.Y+2,256,2)
            $contrasts=@($shots|ForEach-Object{[CompositionNative]::StripeContrast($_.Bitmap,$_.Rect,$stripe)})
            Assert-Proof ($contrasts[0] -gt 1 -and $contrasts[1] -le .7*$contrasts[0]) 'Tab strip blurs the live backdrop without fading labels' @{Contrast=$contrasts;Roi=$stripe}
            $offError=[CompositionNative]::MaxDifference($shots[0].Bitmap,$shots[0].Rect,$shots[2].Bitmap,$shots[2].Rect,$stripe)
            Assert-Proof ($offError -le 3) 'Disabling tab-strip blur restores background pixels' @{MaxChannelError=$offError;Roi=$stripe}
        } finally {foreach($shot in $shots){$shot.Bitmap.Dispose()}}
        Stop-Ghostty $run;$script:patternMode=0
    }
    if($Case -in @('blur','all')){
        $script:patternMode=1;$run=Start-Ghostty 0.5
        $shots=@()
        foreach($state in @('false','true','false')){
            Reload $run @{'background-blur'=$state};$shots+=,(Capture-Proof $run "blur-$state-$($shots.Count)")
        }
        try {
            $client=$shots[0].Client;$bg=[CompositionNative]::BackdropRect
            $stripe=[CompositionNative]::Roi($client.X+[int]($client.Width*.4),$client.Y+[int]($client.Height*.25),256,32)
            $darkX=$bg.X+([Math]::Ceiling(($client.X+[int]($client.Width*.4)-$bg.X)/256)*256)+40
            $dark=[CompositionNative]::Roi($darkX,$client.Y+[int]($client.Height*.75),24,24)
            $light=[CompositionNative]::Roi($darkX+128,$dark.Y,24,24)
            $contrasts=@();foreach($s in $shots){Assert-Foreground $s $script:reference $s.Meta.Name;$contrasts+= [CompositionNative]::StripeContrast($s.Bitmap,$s.Rect,$stripe)}
            Assert-Proof ($contrasts[0] -gt 1 -and $contrasts[1] -le .7*$contrasts[0]) 'Blur reduces stripe contrast by thirty percent' @{Contrast=$contrasts;Roi=$stripe}
            $d=[CompositionNative]::Mean($shots[1].Bitmap,$shots[1].Rect,$dark);$l=[CompositionNative]::Mean($shots[1].Bitmap,$shots[1].Rect,$light)
            Assert-Proof (($l[0]-$d[0]) -ge 5) 'Blur retains underlying large patch contrast' @{Dark=$d;Light=$l;DarkRoi=$dark;LightRoi=$light}
            $offError=[Math]::Abs($contrasts[0]-$contrasts[2]);Assert-Proof ($offError -le 3) 'Blur disables on live reload' @{Contrast=$contrasts}
            foreach($roi in @($stripe,$dark,$light)){
                $err=[CompositionNative]::MaxDifference($shots[0].Bitmap,$shots[0].Rect,$shots[2].Bitmap,$shots[2].Rect,$roi)
                Assert-Proof ($err -le 3) 'Blur off-again restores background pixels' @{MaxChannelError=$err;Roi=$roi}
            }
        } finally {foreach($s in $shots){$s.Bitmap.Dispose()}}
        Reload $run @{'background-blur'='true'}
        $script:patternMode=2
        $darkShot=Capture-Proof $run 'blur-preserves-dark-theme-tint'
        try {
            $mean=[CompositionNative]::Mean($darkShot.Bitmap,$darkShot.Rect,$darkShot.Rois.gray)
            $brightening=0.0
            for($i=0;$i -lt 3;$i++){$brightening=[Math]::Max($brightening,$mean[$i]-$script:opaqueBackground[$i])}
            Assert-Proof ($brightening -le 3) 'Blur over a black backdrop does not lighten the theme background' @{Mean=$mean;OpaqueReference=$script:opaqueBackground;MaxBrightening=$brightening}
            Assert-Foreground $darkShot $script:reference 'blur-preserves-dark-theme-tint'
        } finally {$darkShot.Bitmap.Dispose()}
        $script:patternMode=1
        Send-Key $run.Child 0x53
        $s=Capture-Proof $run 'blur-live-typing-scrolling'
        try {
            $typed=[CompositionNative]::Roi($s.Client.X+20,$s.Client.Y+290,240,60)
            $script:record.LiveInput=@{Key='s';Roi=$typed;Marker=[CompositionNative]::FindColor($s.Bitmap,$s.Rect,$typed,255,255,0)}
            Assert-Foreground $s $script:reference 'blur-live-typing-scrolling'
            $contrast=[CompositionNative]::StripeContrast($s.Bitmap,$s.Rect,$stripe)
            Assert-Proof ($contrast -le .7*$contrasts[0]) 'Blur remains active while typing and scrolling' @{Contrast=$contrast;OffContrast=$contrasts[0];Roi=$stripe}
        } finally {$s.Bitmap.Dispose()}
        Reload $run @{'background-opacity'=1};Check-Frame $run 'blur-opaque' 1
        Stop-Ghostty $run;$script:patternMode=0
    }
    if($Case -in @('creation','lifecycle','all')){
        $run=Start-Ghostty 0.8 'native' @{'window-show-tab-bar'='always';'font-size'='11';'theme'='Catppuccin Mocha';'background-blur'='true'}
        Check-TabCreation $run 'new-tab-always-visible-bar'
        Stop-Ghostty $run
        $run=Start-Ghostty 0.5 'native' @{'window-show-tab-bar'='auto'}
        Check-TabCreation $run 'new-tab-auto-bar'
        Stop-Ghostty $run
    }
    if($Case -in @('lifecycle','all')){
        $run=Start-Ghostty 0.5;Send-Key $run.Child 0x70
        $children=Get-Children $run $run.Top;Assert-Proof ($children.Count -eq 1) 'New tab is active' @{VisibleChildren=$children.Count}
        $run.Child=$children[0]
        Check-TabTransitions $run 'tab-switch-blur-off'
        Reload $run @{'background-blur'='true'}
        Check-TabTransitions $run 'tab-switch-blur-on'
        Reload $run @{'background-blur'='false'}
        Send-Key $run.Child 0x71
        $children=Get-Children $run $run.Top;Assert-Proof ($children.Count -eq 2) 'Split created in second tab' @{VisibleChildren=$children.Count}
        $run.Child=$children[-1];Reload $run @{'background-opacity'=0.8}
        foreach($child in $children){Check-Frame $run 'visible-split-reload' 0.8 $null $run.Top $child}
        Send-Key $run.Child 0x73;$children=Get-Children $run $run.Top;$run.Child=$children[0]
        Check-Frame $run 'hidden-tab-reload' 0.8
        Send-Key $run.Child 0x7A;Check-Frame $run 'forced-before-inheritance' 1
        Send-Key $run.Child 0x70;$children=Get-Children $run $run.Top;$run.Child=$children[0];Check-Frame $run 'new-tab-inherits-forced' 1
        Send-Key $run.Child 0x71;$children=Get-Children $run $run.Top;$run.Child=$children[-1]
        foreach($child in $children){Check-Frame $run 'new-split-inherits-forced' 1 $null $run.Top $child}
        Send-Key $run.Child 0x74;Check-Frame $run 'zoomed-split' 1
        Send-Key $run.Child 0x74
        [CompositionNative]::SetWindowPos($run.Top,[IntPtr]::Zero,0,0,$run.Width-90,$run.Height-60,0x16)|Out-Null;Start-Sleep -Seconds 1
        Check-Frame $run 'resized-split' 1 $null
        [CompositionNative]::ShowWindow($run.Top,7)|Out-Null;Start-Sleep -Milliseconds 500;[CompositionNative]::ShowWindow($run.Top,4)|Out-Null;Start-Sleep -Seconds 1
        Check-Frame $run 'restored-split' 1 $null
        $areas=[CompositionNative]::MonitorAreas
        if($areas.Count -gt 1){
            $beforeDpi=[CompositionNative]::GetDpiForWindow($run.Top)
            foreach($area in $areas){
                [CompositionNative]::SetWindowPos($run.Top,[IntPtr]::Zero,$area.X+30,$area.Y+30,[Math]::Min(900,$area.Width-100),[Math]::Min(680,$area.Height-100),0x50)|Out-Null
                Start-Sleep -Seconds 2
                Check-Frame $run 'monitor-move' 1 $null
                $script:record.Captures[-1].MonitorMove=@{Area=$area;BeforeDpi=$beforeDpi;AfterDpi=[CompositionNative]::GetDpiForWindow($run.Top)}
            }
        }else{$script:record.Unavailable+='Only one monitor: cross-monitor DPI boundary not exercised.'}
        Send-Key $run.Child 0x72;$tops=Get-Tops $run;Assert-Proof ($tops.Count -eq 2) 'New window created' @{Windows=$tops.Count}
        $other=@($tops|Where-Object{$_ -ne $run.Top})[0];$otherChild=(Get-Children $run $other)[0];Check-Frame $run 'new-window-inherits-forced' 1 $null $other $otherChild
        Send-Key $run.Child 0x75;$tops=Get-Tops $run;Assert-Proof ($tops.Count -eq 3) 'Tab detached' @{Windows=$tops.Count}
        $detached=@($tops|Where-Object{$_ -ne $run.Top -and $_ -ne $other})[0];$detachedChildren=Get-Children $run $detached
        foreach($child in $detachedChildren){Check-Frame $run 'detached-tab-inherits-forced' 1 $null $detached $child}
        Send-Key $otherChild 0x76;$tops=Get-Tops $run;$quick=@($tops|Where-Object{$_ -ne $run.Top -and $_ -ne $other -and $_ -ne $detached})
        Assert-Proof ($quick.Count -eq 1) 'Quick terminal opens' @{Windows=$tops.Count}
        $quickChild=(Get-Children $run $quick[0])[0];Check-Frame $run 'quick-configured' 0.8 $null $quick[0] $quickChild
        Reload $run @{'background-opacity'=0.5} $quickChild;Check-Frame $run 'quick-reload' 0.5 $null $quick[0] $quickChild
        Send-Key $quickChild 0x76
        Stop-Ghostty $run
    }
    $script:record.Status='passed'
} catch {
    $script:record.Errors+=$_.Exception.ToString()
    Write-Host $_.Exception.Message
} finally {
    foreach($r in $script:runs){try{Stop-Ghostty $r}catch{$script:record.Errors+=$_.Exception.Message;$script:record.Status='failed'}}
    if($script:backdropStarted){try{[CompositionNative]::StopBackdrop()}catch{$script:record.Errors+=$_.Exception.Message;$script:record.Status='failed'}}
    $script:record.Finished=(Get-Date).ToString('o')
    $script:record | ConvertTo-Json -Depth 15 | Set-Content -Encoding utf8 (Join-Path $OutputDirectory 'composition-results.json')
    Remove-Item -LiteralPath $work -Recurse -Force
}
Write-Output "Composition $Case`: $($script:record.Status); evidence: $OutputDirectory"
if($script:record.Status -ne 'passed'){exit 1}
