using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;
using System.Threading;
using System.Threading.Tasks;

namespace SatoEdit {
  /// ローカル LLM (Ollama) を入れる・起動する (core/localllm.js と同じ)。
  /// 公式の配布ファイル (OllamaSetup.exe) を取ってきて、正規の署名かを確かめてから起動する。モデルの出し入れは画面側が HTTP で行う
  partial class Bridge {
    CancellationTokenSource llmInstallJob;

    /// Ollama が入っている場所 (見つからなければ null)
    static string FindOllama() {
      var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
      var pf = Environment.GetEnvironmentVariable("ProgramFiles") ?? @"C:\Program Files";
      foreach (var p in new[] {
        Path.Combine(local, "Programs", "Ollama", "ollama app.exe"), Path.Combine(local, "Programs", "Ollama", "ollama.exe"),
        Path.Combine(pf, "Ollama", "ollama app.exe"), Path.Combine(pf, "Ollama", "ollama.exe"),
      }) if (File.Exists(p)) return p;
      return null;
    }

    [DllImport("wintrust.dll", CharSet = CharSet.Unicode)] static extern int WinVerifyTrust(IntPtr hwnd, [MarshalAs(UnmanagedType.LPStruct)] Guid action, ref WINTRUST_DATA data);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WINTRUST_FILE_INFO { public uint cbStruct; public string pcwszFilePath; public IntPtr hFile; public IntPtr pgKnownSubject; }
    [StructLayout(LayoutKind.Sequential)]
    struct WINTRUST_DATA {
      public uint cbStruct; public IntPtr pPolicyCallbackData; public IntPtr pSIPClientData; public uint dwUIChoice; public uint fdwRevocationChecks;
      public uint dwUnionChoice; public IntPtr pFile; public uint dwStateAction; public IntPtr hWVTStateData; public IntPtr pwszURLReference;
      public uint dwProvFlags; public uint dwUIContext; public IntPtr pSignatureSettings;
    }

    /// 署名を確かめる: 正しく署名されていて、署名した会社が Ollama か
    static (bool ok, string reason) VerifySignature(string file) {
      var info = new WINTRUST_FILE_INFO { cbStruct = (uint)Marshal.SizeOf(typeof(WINTRUST_FILE_INFO)), pcwszFilePath = file };
      var pInfo = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(WINTRUST_FILE_INFO)));
      try {
        Marshal.StructureToPtr(info, pInfo, false);
        var data = new WINTRUST_DATA { cbStruct = (uint)Marshal.SizeOf(typeof(WINTRUST_DATA)), dwUIChoice = 2, fdwRevocationChecks = 0, dwUnionChoice = 1, pFile = pInfo, dwStateAction = 0, dwProvFlags = 0x80 };
        var action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE"); // WINTRUST_ACTION_GENERIC_VERIFY_V2
        int r = WinVerifyTrust(new IntPtr(-1), action, ref data);
        string subject;
        try { subject = new X509Certificate2(X509Certificate.CreateFromSignedFile(file)).Subject; } catch (Exception e) { subject = e.Message; }
        return (r == 0 && subject.IndexOf("Ollama", StringComparison.OrdinalIgnoreCase) >= 0, (r == 0 ? "Valid" : "0x" + r.ToString("x")) + " " + subject);
      } finally { Marshal.FreeHGlobal(pInfo); }
    }

    void RegisterLocalLLM() {
      On("llmInfo", a => new JObj { { "installed", FindOllama() != null }, { "release", OsRelease() } });
      On("llmStart", a => {
        var exe = FindOllama();
        if (exe == null) return false;
        var args = exe.EndsWith("ollama.exe", StringComparison.OrdinalIgnoreCase) ? "serve" : "";
        Process.Start(new ProcessStartInfo(exe, args) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetDirectoryName(exe) });
        return true;
      });
      On("llmCancelInstall", a => { llmInstallJob?.Cancel(); return true; });
      OnAsync("llmInstall", async a => {
        var url = S(a, 0);
        if (!url.StartsWith("https://")) throw new UserError("bad URL");
        var dest = Path.Combine(Path.GetTempPath(), $"OllamaSetup-{DateTime.Now.Ticks}.exe");
        var cts = new CancellationTokenSource();
        llmInstallJob = cts;
        try {
          await Task.Run(async () => {
            using (var res = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cts.Token)) {
              if ((int)res.StatusCode != 200) throw new UserError("HTTP " + (int)res.StatusCode);
              double total = res.Content.Headers.ContentLength ?? 0, got = 0;
              var last = DateTime.MinValue;
              using (var s = await res.Content.ReadAsStreamAsync())
              using (var f = File.Create(dest)) {
                var buf = new byte[81920];
                int n;
                while ((n = await s.ReadAsync(buf, 0, buf.Length, cts.Token)) > 0) {
                  f.Write(buf, 0, n);
                  got += n;
                  if ((DateTime.Now - last).TotalMilliseconds > 200) { last = DateTime.Now; Send("llm:install", new JObj { { "got", got }, { "total", total } }); }
                }
              }
              Send("llm:install", new JObj { { "got", got }, { "total", total } });
            }
          });
          var sig = await Task.Run(() => VerifySignature(dest));
          if (!sig.ok) throw new UserError("signature: " + sig.reason);
          // インストーラの画面が出る (管理者の権限は要らない。ホームフォルダに入る)
          Process.Start(new ProcessStartInfo(dest) { UseShellExecute = true });
          return true;
        } catch (Exception e) {
          try { File.Delete(dest); } catch { }
          if (cts.IsCancellationRequested) throw new UserError("cancelled");
          throw e is UserError ? e : new UserError(Explain(e));
        } finally {
          llmInstallJob = null;
        }
      });
    }
  }
}
