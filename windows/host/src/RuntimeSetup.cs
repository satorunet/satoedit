using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography.X509Certificates;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace SatoEdit {
  /// 画面の表示に使う Microsoft Edge WebView2 ランタイムが無い PC (更新していない古い Windows 10 など) で、
  /// Microsoft の配布元から小さなインストーラ (Evergreen Bootstrapper) を取ってきて入れる。管理者の権限が無ければ、そのユーザーだけに入る
  static class RuntimeSetup {
    const string BootstrapperURL = "https://go.microsoft.com/fwlink/p/?LinkId=2124703";

    /// 入れたら true (そのあと画面を作り直す)
    public static async Task<bool> Offer(Form owner) {
      var ja = System.Globalization.CultureInfo.CurrentUICulture.Name.StartsWith("ja");
      var msg = ja
        ? "画面の表示に使う「Microsoft Edge WebView2 ランタイム」がこの PC に入っていません。\n\nMicrosoft の配布元から取ってきて入れますか? (インターネットにつながっている必要があります。数分かかります)"
        : "This PC does not have the Microsoft Edge WebView2 Runtime, which satoEdit uses to draw its window.\n\nDownload and install it from Microsoft now? (Requires an internet connection. Takes a few minutes.)";
      if (MessageBox.Show(owner, msg, ja ? "satoEdit" : "satoEdit", MessageBoxButtons.YesNo, MessageBoxIcon.Information) != DialogResult.Yes) return false;
      owner.UseWaitCursor = true;
      var file = Path.Combine(Path.GetTempPath(), "MicrosoftEdgeWebview2Setup-" + DateTime.Now.Ticks + ".exe");
      try {
        using (var c = new HttpClient { Timeout = TimeSpan.FromMinutes(5) }) {
          var data = await c.GetByteArrayAsync(BootstrapperURL);
          File.WriteAllBytes(file, data);
        }
        // Microsoft の正しい署名かを確かめる
        var subject = new X509Certificate2(X509Certificate.CreateFromSignedFile(file)).Subject;
        if (subject.IndexOf("O=Microsoft Corporation", StringComparison.OrdinalIgnoreCase) < 0) throw new Exception("signature: " + subject);
        var p = Process.Start(new ProcessStartInfo(file, "/install") { UseShellExecute = true });
        await Task.Run(() => p.WaitForExit());
        return true;
      } catch (Exception e) {
        Log.Error("runtime setup", e);
        MessageBox.Show(owner, (ja ? "入れられませんでした。次のページから入れてください。\n" : "Could not install it. Please get it from this page:\n")
          + "https://developer.microsoft.com/microsoft-edge/webview2/\n\n" + e.Message, "satoEdit", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        MainForm.OpenExternal("https://developer.microsoft.com/microsoft-edge/webview2/");
        return false;
      } finally {
        owner.UseWaitCursor = false;
        try { File.Delete(file); } catch { }
      }
    }
  }
}
