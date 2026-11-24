Add-Type -ReferencedAssemblies System.Drawing @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
public static class OwnedTestWindows {
    public static uint Pid;
    delegate bool EnumProc(IntPtr h, IntPtr data);
    [DllImport("user32")] static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32")] static extern bool EnumChildWindows(IntPtr h, EnumProc callback, IntPtr data);
    [DllImport("user32")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32")] static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32")] static extern bool GetGUIThreadInfo(uint thread, ref Gui info);
    [DllImport("user32", CharSet=CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr h, uint m, UIntPtr w, StringBuilder l, uint flags, uint timeout, out UIntPtr result);
    [StructLayout(LayoutKind.Sequential)] struct Point { public int x, y; }
    [DllImport("user32")] static extern bool ClientToScreen(IntPtr h, ref Point p);
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int l, t, r, b; }
    [DllImport("user32")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32")] static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [StructLayout(LayoutKind.Sequential)] struct Gui {
        public uint size, flags;
        public IntPtr active, focus, capture, menu, move, caret;
        public int left, top, right, bottom;
    }
    static bool Ours(IntPtr h) { uint pid; return GetWindowThreadProcessId(h, out pid) != 0 && pid == Pid; }
    public static IntPtr[] Find(string type, IntPtr parent) {
        var found = new List<IntPtr>();
        EnumProc check = delegate(IntPtr h, IntPtr _) {
            var name = new StringBuilder(64);
            if (Ours(h) && IsWindowVisible(h) && GetClassName(h, name, name.Capacity) != 0 && name.ToString() == type) found.Add(h);
            return true;
        };
        if (parent == IntPtr.Zero) EnumWindows(check, IntPtr.Zero);
        else if (Ours(parent)) EnumChildWindows(parent, check, IntPtr.Zero);
        return found.ToArray();
    }
    public static IntPtr Focus(IntPtr h) {
        uint pid, thread = GetWindowThreadProcessId(h, out pid);
        var info = new Gui(); info.size = (uint)Marshal.SizeOf(info);
        return pid == Pid && GetGUIThreadInfo(thread, ref info) ? info.focus : IntPtr.Zero;
    }
    public static string Title(IntPtr h) {
        var s = new StringBuilder(512); if (Ours(h)) GetWindowText(h, s, s.Capacity);
        return s.ToString();
    }
    public static string ControlText(IntPtr h) {
        var s = new StringBuilder(128); UIntPtr result;
        if (!Ours(h) || SendMessageTimeout(h, 0xD, (UIntPtr)128, s, 3, 500, out result) == IntPtr.Zero) return "";
        return s.ToString();
    }
    public static bool HasColor(IntPtr h, uint rgb) {
        IntPtr root = GetAncestor(h, 2);
        var p = new Point { x = 30, y = 30 }; Rect r;
        if (!Ours(h) || !Ours(root) || !ClientToScreen(h, ref p) || !GetWindowRect(root, out r)) return false;
        using (var bitmap = new Bitmap(r.r-r.l, r.b-r.t)) {
            using (var graphics = Graphics.FromImage(bitmap)) {
                var dc = graphics.GetHdc();
                try { if (!PrintWindow(root, dc, 2)) return false; }
                finally { graphics.ReleaseHdc(dc); }
            }
            var pixel = bitmap.GetPixel(p.x-r.l, p.y-r.t);
            return Math.Abs(pixel.R - (int)(rgb & 255)) <= 3 &&
                   Math.Abs(pixel.G - (int)((rgb >> 8) & 255)) <= 3 &&
                   Math.Abs(pixel.B - (int)((rgb >> 16) & 255)) <= 3;
        }
    }
    public static void Post(IntPtr h, uint msg, int value, int flags) {
        if (!Ours(h) || !PostMessageW(h, msg, new IntPtr(value), new IntPtr(flags)))
            throw new Exception("Failed to post to the test process");
    }
    public static void Key(IntPtr h, int key) { Post(h, 0x100, key, 1); Post(h, 0x101, key, unchecked((int)0xC0000001)); }
}
'@
