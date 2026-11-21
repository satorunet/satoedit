using System;
using System.IO;
using System.Runtime.InteropServices;

namespace SatoEdit {
  /// Windows の機能を直接呼ぶところ
  static class Win32 {
    [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int dwProcessId);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
    [DllImport("user32.dll")] static extern bool FlashWindowEx(ref FLASHWINFO pwfi);
    /// タスクバーのボタンを光らせる (ウインドウを前に出すまで)
    public static void Flash(IntPtr hwnd) {
      var f = new FLASHWINFO { cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO)), hwnd = hwnd, dwFlags = 2 | 12, uCount = 0, dwTimeout = 0 };
      FlashWindowEx(ref f);
    }

    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    /// タイトルバーを暗い色にする (Windows 10 2004 以降)
    public static void DarkTitleBar(IntPtr hwnd, bool dark) {
      int v = dark ? 1 : 0;
      if (DwmSetWindowAttribute(hwnd, 20, ref v, 4) != 0) DwmSetWindowAttribute(hwnd, 19, ref v, 4);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEOPSTRUCT {
      public IntPtr hwnd; public uint wFunc;
      public string pFrom; public string pTo;
      public ushort fFlags; public bool fAnyOperationsAborted; public IntPtr hNameMappings; public string lpszProgressTitle;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHFileOperation(ref SHFILEOPSTRUCT op);

    /// ごみ箱へ (元に戻せる)
    public static void Trash(string path) {
      if (!File.Exists(path) && !Directory.Exists(path)) throw new FileNotFoundException("ファイルが見つかりません: " + path);
      const uint FO_DELETE = 3;
      const ushort FOF_SILENT = 0x4, FOF_NOCONFIRMATION = 0x10, FOF_ALLOWUNDO = 0x40, FOF_NOERRORUI = 0x400;
      var op = new SHFILEOPSTRUCT { wFunc = FO_DELETE, pFrom = Path.GetFullPath(path) + "\0\0", fFlags = FOF_SILENT | FOF_NOCONFIRMATION | FOF_ALLOWUNDO | FOF_NOERRORUI };
      int r = SHFileOperation(ref op);
      if (r != 0 || op.fAnyOperationsAborted) throw new IOException("ごみ箱に入れられませんでした (" + r + ")");
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEINFO {
      public IntPtr hIcon; public int iIcon; public uint dwAttributes;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SHGetFileInfo(string pszPath, uint attr, ref SHFILEINFO psfi, uint cb, uint flags);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);

    /// 拡張子のアイコン (小さいほう) → PNG
    public static byte[] FileIconPng(string ext, bool large = false) {
      const uint SHGFI_ICON = 0x100, SHGFI_SMALLICON = 0x1, SHGFI_USEFILEATTRIBUTES = 0x10, FILE_ATTRIBUTE_NORMAL = 0x80;
      var info = new SHFILEINFO();
      SHGetFileInfo("probe." + ext, FILE_ATTRIBUTE_NORMAL, ref info, (uint)Marshal.SizeOf(typeof(SHFILEINFO)), SHGFI_ICON | (large ? 0 : SHGFI_SMALLICON) | SHGFI_USEFILEATTRIBUTES);
      if (info.hIcon == IntPtr.Zero) return null;
      try {
        using (var icon = System.Drawing.Icon.FromHandle(info.hIcon))
        using (var bmp = icon.ToBitmap())
        using (var ms = new MemoryStream()) {
          bmp.Save(ms, System.Drawing.Imaging.ImageFormat.Png);
          return ms.ToArray();
        }
      } finally { DestroyIcon(info.hIcon); }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool MoveFileEx(string from, string to, int flags);
    /// 置き換えて名前を変える (書きかけのファイルが残らないように)
    public static void ReplaceFile(string from, string to) {
      if (!MoveFileEx(from, to, 1 | 2)) throw new IOException(new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()).Message);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern void SHAddToRecentDocs(uint flags, string path);
    public static void AddRecentDocument(string path) { try { SHAddToRecentDocs(3, path); } catch { } }
    public static void ClearRecentDocuments() { try { SHAddToRecentDocs(3, null); } catch { } }

    [DllImport("shell32.dll", SetLastError = true)] static extern void SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string id);
    public static void SetAppId(string id) { try { SetCurrentProcessExplicitAppUserModelID(id); } catch { } }
  }
}
