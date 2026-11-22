using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace SatoEdit {
  /// アップデート: GitHub Releases (satorunet/satoedit) の最新の版を確かめ、インストーラーを取ってきて入れ替える。
  /// 確かめる先は --update-url=… か環境変数 SATOEDIT_UPDATE_URL で変えられる (自己点検ではこの PC の JSON ファイル)
  static class Updater {
    public const string DefaultURL = "https://api.github.com/repos/satorunet/satoedit/releases/latest";
    public static string UrlOverride;
    /// 自己点検の間は、自動の確認をしない
    public static bool AutoDisabled;

    public static string URL {
      get {
        if (!string.IsNullOrEmpty(UrlOverride)) return UrlOverride;
        var env = Environment.GetEnvironmentVariable("SATOEDIT_UPDATE_URL");
        return string.IsNullOrEmpty(env) ? DefaultURL : env;
      }
    }

    public static string DownloadDir => Path.Combine(Path.GetTempPath(), "satoruEditor-update");
    /// インストーラーが入れる先 (installer/Setup.cs の InstallDir と同じ)
    public static string InstallDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "satoruEditor");

    static readonly HttpClient http = MakeClient();
    static HttpClient MakeClient() {
      try { ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12; } catch { }
      var h = new HttpClientHandler { AllowAutoRedirect = true, MaxAutomaticRedirections = 8, AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate };
      var c = new HttpClient(h) { Timeout = Timeout.InfiniteTimeSpan };
      c.DefaultRequestHeaders.UserAgent.ParseAdd("satoruEditor-updater/" + Program.Version);
      return c;
    }

    /// "C:\…\x.json" や "file:///C:/…" はこの PC のファイル
    static string LocalPath(string url) {
      if (Uri.TryCreate(url, UriKind.Absolute, out var u)) return u.IsFile ? u.LocalPath : null;
      return Path.IsPathRooted(url) ? url : null;
    }

    /// 最新の版を確かめる → UpdateInfo.Parse の形。うまくいかなければ { status: "error", message }
    public static async Task<JObj> Check(string url, string current, CancellationToken ct = default(CancellationToken)) {
      try {
        string text;
        var local = LocalPath(url);
        if (local != null) {
          text = File.ReadAllText(local, Encoding.UTF8);
        } else {
          using (var cts = CancellationTokenSource.CreateLinkedTokenSource(ct)) {
            cts.CancelAfter(TimeSpan.FromSeconds(20));
            var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.TryAddWithoutValidation("Accept", "application/vnd.github+json");
            using (var res = await http.SendAsync(req, cts.Token).ConfigureAwait(false)) {
              text = await res.Content.ReadAsStringAsync().ConfigureAwait(false);
              if ((int)res.StatusCode == 404) return Error(current, "HTTP 404 (公開している版がまだありません)");
              if (!res.IsSuccessStatusCode) return Error(current, "HTTP " + (int)res.StatusCode + " " + res.ReasonPhrase);
            }
          }
        }
        return UpdateInfo.Parse(Json.Parse(text), current);
      } catch (Exception e) {
        return Error(current, Explain(e));
      }
    }

    static JObj Error(string current, string message) => new JObj { { "status", "error" }, { "current", current }, { "message", message } };

    static string Explain(Exception e) {
      while ((e is AggregateException || e is HttpRequestException || e is WebException) && e.InnerException != null) e = e.InnerException;
      if (e is TaskCanceledException || e is OperationCanceledException) return "timeout";
      return e.Message;
    }

    /// インストーラーを一時フォルダに取ってくる → 置いた場所。大きさが GitHub の示す大きさと合うか、exe の形かを確かめる
    /// (配布している setup.exe はコード署名をしていないので、署名は確かめない)
    public static async Task<string> Download(JObj asset, Action<long, long> progress, CancellationToken ct) {
      var name = Path.GetFileName(asset.Str("name"));
      if (!UpdateInfo.AssetName.IsMatch(name)) throw new UserError("ファイルの名前が違います: " + name);
      long expected = (long)asset.Num("size");
      Directory.CreateDirectory(DownloadDir);
      var dest = Path.Combine(DownloadDir, name);
      var part = dest + ".part";
      try {
        long got = 0, total = expected;
        Stream src;
        HttpResponseMessage res = null;
        var local = LocalPath(asset.Str("url"));
        if (local != null) {
          src = File.OpenRead(local);
        } else {
          res = await http.GetAsync(asset.Str("url"), HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
          if (!res.IsSuccessStatusCode) throw new UserError("HTTP " + (int)res.StatusCode + " " + res.ReasonPhrase);
          if (total <= 0) total = res.Content.Headers.ContentLength ?? 0;
          src = await res.Content.ReadAsStreamAsync().ConfigureAwait(false);
        }
        using (res)
        using (src)
        using (var outs = File.Create(part)) {
          var buf = new byte[81920];
          long lastReport = -1;
          var clock = Stopwatch.StartNew();
          while (true) {
            int n;
            using (var idle = CancellationTokenSource.CreateLinkedTokenSource(ct)) {
              idle.CancelAfter(TimeSpan.FromSeconds(60)); // 1 分なにも来なければ、あきらめる
              n = await src.ReadAsync(buf, 0, buf.Length, idle.Token).ConfigureAwait(false);
            }
            if (n <= 0) break;
            await outs.WriteAsync(buf, 0, n, ct).ConfigureAwait(false);
            got += n;
            if (clock.ElapsedMilliseconds - lastReport >= 100) { lastReport = clock.ElapsedMilliseconds; progress?.Invoke(got, total); }
          }
        }
        progress?.Invoke(got, total);
        var size = new FileInfo(part).Length;
        if (expected > 0 && size != expected) throw new UserError($"ダウンロードしたファイルの大きさが違います ({size} / {expected} バイト)");
        if (size < 1024 || !LooksLikeExe(part)) throw new UserError("ダウンロードしたファイルがインストーラーではありません");
        if (File.Exists(dest)) File.Delete(dest);
        File.Move(part, dest);
        return dest;
      } catch {
        try { File.Delete(part); } catch { }
        throw;
      }
    }

    static bool LooksLikeExe(string file) {
      using (var f = File.OpenRead(file)) return f.ReadByte() == 'M' && f.ReadByte() == 'Z';
    }

    /// インストーラーに渡す引数: 入れた先 (%LOCALAPPDATA%\Programs\satoruEditor) から動いているなら、画面を出さずに入れ替えて起動し直す (/update)。
    /// zip を広げた所から動いているときは、ふつうのインストールの画面を出す (入れる先を見てもらう)
    public static string InstallerArgs(string exeDir, int pid) {
      // ポータブル版: 今の場所のまま中身だけ入れ替える (data と portable.txt はそのまま)
      if (Portable.On) return "/portable=\"" + Path.GetFullPath(exeDir).TrimEnd('\\') + "\" /wait-pid=" + pid;
      var installed = string.Equals(Path.GetFullPath(exeDir).TrimEnd('\\'), Path.GetFullPath(InstallDir).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
      return installed ? "/update /wait-pid=" + pid : "";
    }

    /// 取ってきたインストーラーを起動する (アプリはこのあと閉じる)
    public static void StartInstaller(string file) {
      var full = Path.GetFullPath(file);
      if (!full.StartsWith(Path.GetFullPath(DownloadDir) + "\\", StringComparison.OrdinalIgnoreCase) || !File.Exists(full) || !UpdateInfo.AssetName.IsMatch(Path.GetFileName(full)))
        throw new UserError("インストーラーが見つかりません");
      var args = InstallerArgs(AppDomain.CurrentDomain.BaseDirectory, Process.GetCurrentProcess().Id);
      Log.Write("update: start " + full + " " + args);
      Process.Start(new ProcessStartInfo(full, args) { UseShellExecute = true, WorkingDirectory = DownloadDir });
    }
  }
}
