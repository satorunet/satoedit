using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace SatoEdit {
  /// ファイルを選ぶ・保存先を選ぶ・お知らせのダイアログ
  static class Dialogs {
    /// filters: [{ name, extensions: ['txt', '*'] }] → "名前|*.txt"
    static string Filter(List<object> filters) {
      if (filters == null || filters.Count == 0) return "*.*|*.*";
      var parts = new List<string>();
      foreach (var f in filters.OfType<JObj>()) {
        var exts = (f.Arr("extensions") ?? new List<object>()).Select(x => x as string ?? "").Where(x => x != "").Select(x => x == "*" ? "*.*" : "*." + x).ToList();
        if (exts.Count == 0) exts.Add("*.*");
        var pattern = string.Join(";", exts);
        parts.Add(f.Str("name").Replace("|", " ") + "|" + pattern);
      }
      return string.Join("|", parts);
    }

    static void Place(FileDialog d, string defaultPath) {
      if (string.IsNullOrEmpty(defaultPath)) return;
      try {
        if (Directory.Exists(defaultPath)) { d.InitialDirectory = defaultPath; return; }
        var dir = Path.GetDirectoryName(defaultPath);
        if (!string.IsNullOrEmpty(dir) && Directory.Exists(dir)) d.InitialDirectory = dir;
        d.FileName = Path.GetFileName(defaultPath);
      } catch { }
    }

    public static List<string> Open(IWin32Window owner, JObj o) {
      if (o.Bool("directory")) {
        var dir = PickFolder(owner, o.Str("title"), o.Str("defaultPath"));
        return dir == null ? new List<string>() : new List<string> { dir };
      }
      using (var d = new OpenFileDialog { Title = o.Str("title"), Multiselect = !o.Bool("single"), Filter = Filter(o.Arr("filters")), RestoreDirectory = true }) {
        Place(d, o.Str("defaultPath"));
        if (File.Exists(o.Str("defaultPath")) == false) d.FileName = "";
        return d.ShowDialog(owner) == DialogResult.OK ? d.FileNames.ToList() : new List<string>();
      }
    }

    public static string Save(IWin32Window owner, JObj o) {
      var filters = o.Arr("filters");
      // anyExtension: 文書の保存。どんな拡張子でも、そのまま (注意も出さない)。拡張子を書かなかったときだけ .txt を付ける (Mac 版と同じ)
      bool any = o.Bool("anyExtension");
      using (var d = new SaveFileDialog { Title = o.Str("title"), Filter = Filter(filters), OverwritePrompt = true, AddExtension = !any, RestoreDirectory = true }) {
        var first = (filters?.OfType<JObj>().FirstOrDefault()?.Arr("extensions") ?? new List<object>()).OfType<string>().FirstOrDefault(x => x != "*");
        if (first != null) d.DefaultExt = first;
        Place(d, o.Str("defaultPath"));
        // 名前の拡張子に合う種類を最初に選んでおく
        var ext = Path.GetExtension(d.FileName ?? "").TrimStart('.').ToLowerInvariant();
        if (ext != "" && filters != null) {
          int i = 1;
          foreach (var f in filters.OfType<JObj>()) {
            if ((f.Arr("extensions") ?? new List<object>()).OfType<string>().Any(x => x.ToLowerInvariant() == ext)) { d.FilterIndex = i; break; }
            i++;
          }
        }
        if (d.ShowDialog(owner) != DialogResult.OK) return null;
        var file = d.FileName;
        if (any && Path.GetExtension(file) == "") {
          file += ".txt";
          if (File.Exists(file) && MessageBox.Show(owner, o.Str("replaceAsk", "{name}").Replace("{name}", Path.GetFileName(file)), d.Title, MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return null;
        }
        return file;
      }
    }

    // ---------- フォルダを選ぶ (Vista 以降の新しい形のダイアログ) ----------

    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")] class FileOpenDialogRCW { }

    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFileDialog {
      [PreserveSig] int Show(IntPtr parent);
      void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
      void SetFileTypeIndex(uint iFileType);
      void GetFileTypeIndex(out uint piFileType);
      void Advise(IntPtr pfde, out uint pdwCookie);
      void Unadvise(uint dwCookie);
      void SetOptions(uint fos);
      void GetOptions(out uint pfos);
      void SetDefaultFolder(IShellItem psi);
      void SetFolder(IShellItem psi);
      void GetFolder(out IShellItem ppsi);
      void GetCurrentSelection(out IShellItem ppsi);
      void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
      void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
      void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
      void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
      void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
      void GetResult(out IShellItem ppsi);
      void AddPlace(IShellItem psi, int fdap);
      void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
      void Close(int hr);
      void SetClientGuid(ref Guid guid);
      void ClearClientData();
      void SetFilter(IntPtr pFilter);
    }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItem {
      void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
      void GetParent(out IShellItem ppsi);
      void GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
      void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
      void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string pszPath, IntPtr pbc, [MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IShellItem ppv);

    public static string PickFolder(IWin32Window owner, string title, string defaultPath) {
      var dlg = (IFileDialog)new FileOpenDialogRCW();
      try {
        const uint FOS_PICKFOLDERS = 0x20, FOS_FORCEFILESYSTEM = 0x40, FOS_NOCHANGEDIR = 0x8, FOS_PATHMUSTEXIST = 0x800;
        dlg.SetOptions(FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_NOCHANGEDIR | FOS_PATHMUSTEXIST);
        if (!string.IsNullOrEmpty(title)) dlg.SetTitle(title);
        if (!string.IsNullOrEmpty(defaultPath) && Directory.Exists(defaultPath)) {
          try {
            SHCreateItemFromParsingName(defaultPath, IntPtr.Zero, typeof(IShellItem).GUID, out var item);
            dlg.SetFolder(item);
          } catch { }
        }
        if (dlg.Show(owner?.Handle ?? IntPtr.Zero) != 0) return null;
        dlg.GetResult(out var result);
        result.GetDisplayName(0x80058000, out var path); // SIGDN_FILESYSPATH
        return path;
      } finally {
        Marshal.ReleaseComObject(dlg);
      }
    }

    // ---------- お知らせ (ボタンを選べる) ----------

    /// → 押したボタンの番号 (閉じたら cancelId)
    public static int Message(IWin32Window owner, string title, string message, string detail, IList<string> buttons, int defaultId, int cancelId, Icon icon) {
      using (var f = new Form {
        Text = title, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false, ShowInTaskbar = false,
        StartPosition = FormStartPosition.CenterParent, AutoScaleMode = AutoScaleMode.Dpi, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
        Font = SystemFonts.MessageBoxFont, BackColor = SystemColors.Window, Padding = new Padding(0),
      }) {
        int result = cancelId;
        var layout = new TableLayoutPanel { ColumnCount = 2, RowCount = 3, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(16), Dock = DockStyle.Fill };
        if (icon != null) layout.Controls.Add(new PictureBox { Image = new Bitmap(icon.ToBitmap(), 48, 48), SizeMode = PictureBoxSizeMode.Zoom, Size = new Size(48, 48), Margin = new Padding(0, 0, 16, 0) }, 0, 0);
        layout.Controls.Add(new Label { Text = message, AutoSize = true, MaximumSize = new Size(440, 0), Font = new Font(SystemFonts.MessageBoxFont.FontFamily, SystemFonts.MessageBoxFont.Size * 1.25f), ForeColor = Color.FromArgb(0x00, 0x33, 0x99), Margin = new Padding(0, 4, 0, 8) }, 1, 0);
        if (!string.IsNullOrEmpty(detail)) layout.Controls.Add(new Label { Text = detail, AutoSize = true, MaximumSize = new Size(440, 0), Margin = new Padding(0, 0, 0, 12) }, 1, 1);
        var bar = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill, Margin = new Padding(0, 8, 0, 0) };
        for (int i = buttons.Count - 1; i >= 0; i--) {
          int n = i;
          var b = new Button { Text = buttons[i], AutoSize = true, MinimumSize = new Size(88, 28), Margin = new Padding(6, 0, 0, 0) };
          b.Click += (s, e) => { result = n; f.Close(); };
          bar.Controls.Add(b);
          if (i == defaultId) f.AcceptButton = b;
          if (i == cancelId) f.CancelButton = b;
        }
        layout.Controls.Add(bar, 0, 2);
        layout.SetColumnSpan(bar, 2);
        f.Controls.Add(layout);
        f.ShowDialog(owner);
        return result;
      }
    }
  }
}
