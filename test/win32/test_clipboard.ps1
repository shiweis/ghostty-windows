param([Parameter(Mandatory=$true)][string]$TestExe)
# Build ghostty-test with -Dtest-filter="Windows clipboard" -Demit-test-exe=true.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class PrivateClipboardTests {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct Startup {
        public int cb;
        public string reserved, desktop, title;
        public uint x,y,w,h,columns,rows,fill,flags;
        public short show,reserved2;
        public IntPtr reserved3,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct Child { public IntPtr process,thread; public uint pid,tid; }
    delegate bool EnumWindow(IntPtr hwnd, IntPtr param);
    [DllImport("user32",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern IntPtr CreateWindowStation(string name,uint flags,uint access,IntPtr security);
    [DllImport("user32",SetLastError=true)] static extern bool SetProcessWindowStation(IntPtr station);
    [DllImport("user32")] static extern IntPtr GetProcessWindowStation();
    [DllImport("user32")] static extern bool CloseWindowStation(IntPtr station);
    [DllImport("user32",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetUserObjectInformation(IntPtr obj,int index,StringBuilder buf,int count,out int needed);
    [DllImport("user32",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern IntPtr CreateDesktop(string name,IntPtr device,IntPtr mode,uint flags,uint access,IntPtr security);
    [DllImport("user32")] static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32",SetLastError=true)] static extern bool SetThreadDesktop(IntPtr desktop);
    [DllImport("user32")] static extern bool EnumDesktopWindows(IntPtr desktop,EnumWindow fn,IntPtr param);
    [DllImport("user32")] static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
    [DllImport("user32",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd,StringBuilder name,int cap);
    [DllImport("user32",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd,StringBuilder name,int cap);
    [DllImport("user32")] static extern bool PostMessage(IntPtr hwnd,uint msg,IntPtr w,IntPtr l);
    [DllImport("kernel32",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern bool CreateProcess(string app,StringBuilder args,IntPtr pa,IntPtr ta,bool inherit,
        uint flags,IntPtr env,string cwd,ref Startup start,out Child child);
    [DllImport("kernel32")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32")] static extern bool TerminateProcess(IntPtr process,uint code);
    [DllImport("kernel32")] static extern uint WaitForSingleObject(IntPtr handle,uint ms);
    [DllImport("kernel32")] static extern bool GetExitCodeProcess(IntPtr handle,out uint code);
    static void Check(bool success, string action = "Win32 call") { if (!success) throw new Win32Exception(Marshal.GetLastWin32Error(), action + " failed with " + Marshal.GetLastWin32Error()); }

    [DllImport("advapi32",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool LogonUser(string user,string domain,string password,int type,int provider,out IntPtr token);
    [DllImport("advapi32",SetLastError=true)] static extern bool ImpersonateLoggedOnUser(IntPtr token);
    [DllImport("advapi32",SetLastError=true)] static extern bool RevertToSelf();

    // An unelevated process may only create the station named for its logon
    // session. A fresh network-only logon supplies a unique station name;
    // it keeps the caller's local identity and this test uses no network.
    static IntPtr CreatePrivateStation() {
        IntPtr token;
        Check(LogonUser("GhosttyClipboardTest",".",Guid.NewGuid().ToString("N"),9,3,out token),"Create local test logon session");
        try {
            Check(ImpersonateLoggedOnUser(token),"Select test logon session");
            try {
                IntPtr station = CreateWindowStation(null,1,0x000F037F,IntPtr.Zero);
                Check(station != IntPtr.Zero, "CreateWindowStation");
                return station;
            } finally { Check(RevertToSelf(),"Restore local identity"); }
        } finally { CloseHandle(token); }
    }

    public static void Run(string exe,string log) {
        if (exe.StartsWith(@"\\"))
            throw new ArgumentException("Stage the test executable and its runtime DLLs on a local Windows drive.");
        string desktopName = "GhosttyClipboardTest-" + Guid.NewGuid().ToString("N");
        IntPtr station = CreatePrivateStation();
        IntPtr desktop = IntPtr.Zero;
        IntPtr previous = GetProcessWindowStation();
        try {
            var name = new StringBuilder(256);
            int needed;
            Check(GetUserObjectInformation(station,2,name,512,out needed), "Read private window station name");
            if (name.ToString().Equals("WinSta0",StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Interactive window station");
            Check(SetProcessWindowStation(station), "SetProcessWindowStation");
            desktop = CreateDesktop(desktopName,IntPtr.Zero,IntPtr.Zero,0,0x000F01FF,IntPtr.Zero);
            Check(desktop != IntPtr.Zero, "CreateDesktop");
            using (var output = new FileStream(log,FileMode.Create,FileAccess.ReadWrite,
                                               FileShare.ReadWrite | FileShare.Inheritable)) {
                var start = new Startup();
                start.cb = Marshal.SizeOf(typeof(Startup));
                start.desktop = name.ToString() + @"\" + desktopName;
                start.flags = 0x100;
                start.output = start.error = start.input = output.SafeFileHandle.DangerousGetHandle();
                Child child;
                Check(CreateProcess(exe,new StringBuilder("\""+exe+"\""),IntPtr.Zero,IntPtr.Zero,true,
                    0x08000000,IntPtr.Zero,Path.GetDirectoryName(exe),ref start,out child), "CreateProcess");
                CloseHandle(child.thread);
                try {
                    Exception workerError = null;
                    var worker = new Thread(delegate() { try {
                        Check(SetThreadDesktop(desktop), "Select test desktop");
                        int[] buttons = {6,7,2};
                        int seen = 0;
                        IntPtr last = IntPtr.Zero;
                        var timer = Stopwatch.StartNew();
                        var observed = new Dictionary<IntPtr,string>();
                        while (WaitForSingleObject(child.process,25) == 258) {
                            if (timer.Elapsed.TotalSeconds > 30) throw new TimeoutException("Private clipboard test timed out after "+seen+" dialogs. Windows: "+string.Join(", ",observed.Values));
                            EnumDesktopWindows(desktop,delegate(IntPtr hwnd,IntPtr unused) {
                                uint pid;
                                GetWindowThreadProcessId(hwnd,out pid);
                                if (pid != child.pid || hwnd == last) return true;
                                var text = new StringBuilder(256);
                                GetClassName(hwnd,text,text.Capacity);
                                var cls = text.ToString();
                                GetWindowText(hwnd,text,text.Capacity);
                                observed[hwnd] = cls + " / " + text.ToString();
                                if (cls != "#32770") return true;
                                if (text.ToString() != "Ghostty" || seen >= buttons.Length) return true;
                                if (seen == 0) Check(PostMessage(hwnd,0x0400+113,(IntPtr)1,IntPtr.Zero));
                                Check(PostMessage(hwnd,0x0400+102,(IntPtr)buttons[seen++],IntPtr.Zero));
                                last = hwnd;
                                return true;
                            },IntPtr.Zero);
                        }
                        uint status;
                        Check(GetExitCodeProcess(child.process,out status));
                        if (status != 0 || seen != buttons.Length)
                            throw new InvalidOperationException("Test exit "+status+", observed "+seen+" of 3 dialogs. See "+log);
                    } catch (Exception e) { workerError = e; } });
                    worker.Start();
                    worker.Join();
                    if (workerError != null) throw workerError;
                } finally {
                    if (WaitForSingleObject(child.process,0) == 258) TerminateProcess(child.process,1);
                    CloseHandle(child.process);
                }
            }
        } finally {
            Check(SetProcessWindowStation(previous), "Restore window station");
            if (desktop != IntPtr.Zero) CloseDesktop(desktop);
            CloseWindowStation(station);
        }
    }
}
'@
$log = Join-Path $env:TEMP ('ghostty-private-clipboard-' + [guid]::NewGuid().ToString('N') + '.log')
try {
    [PrivateClipboardTests]::Run((Resolve-Path -LiteralPath $TestExe).ProviderPath, $log)
} finally {
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log }
}
