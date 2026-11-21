using System;
using System.Threading;
using System.Threading.Tasks;

namespace SatoEdit {
  /// アップデート (確かめる・取ってくる・入れ替える)。知らせる画面は renderer/src/updater.js
  partial class Bridge {
    CancellationTokenSource updateJob;

    void RegisterUpdate() {
      // { auto } → { status: update | latest | noasset | skipped | off | notyet | error, version, current, notes, asset, message }
      OnAsync("updateCheck", async a => {
        var auto = O(a, 0).Bool("auto");
        var current = Program.Version;
        if (auto) {
          var enabled = !(Store.Prefs["autoUpdateCheck"] is bool b) || b;
          if (Updater.AutoDisabled) enabled = false;
          var now = (DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
          var gate = UpdateInfo.AutoGate(enabled, Store.Prefs.Num("updateLastCheck"), now);
          if (gate != "go") return new JObj { { "status", gate }, { "current", current } };
          Store.Prefs["updateLastCheck"] = Math.Floor(now);
          Store.SavePrefsSoon();
        }
        var r = await Task.Run(() => Updater.Check(Updater.URL, current));
        if (r.Str("status") == "error") Log.Write("update check: " + r.Str("message"));
        return UpdateInfo.Decide(r, auto, Store.Prefs.Str("updateSkipVersion"));
      });
      // asset ({ name, url, size }) → { status: ok, path } | { status: cancel } | { status: error, message }。途中で update:progress (受け取った, 全体)
      OnAsync("updateDownload", async a => {
        var asset = O(a, 0);
        updateJob?.Cancel();
        var job = updateJob = new CancellationTokenSource();
        try {
          var path = await Task.Run(() => Updater.Download(asset, (got, total) => Send("update:progress", (double)got, (double)total), job.Token));
          return new JObj { { "status", "ok" }, { "path", path } };
        } catch (Exception) when (job.IsCancellationRequested) {
          return new JObj { { "status", "cancel" } };
        } catch (Exception e) {
          Log.Error("update download", e);
          var inner = e is AggregateException ag && ag.InnerException != null ? ag.InnerException : e;
          return new JObj { { "status", "error" }, { "message", inner.Message } };
        } finally {
          if (updateJob == job) updateJob = null;
        }
      });
      On("updateCancel", a => { updateJob?.Cancel(); return true; });
      // 取ってきたインストーラーを起動して、アプリを閉じる (保存していない文書は画面側で先に確かめてある)
      On("updateInstall", a => {
        try {
          Updater.StartInstaller(S(a, 0));
        } catch (Exception e) {
          Log.Error("update install", e);
          return new JObj { { "status", "error" }, { "message", e.Message } };
        }
        form.BeginInvoke((Action)form.CloseNow);
        return new JObj { { "status", "ok" } };
      });
    }
  }
}
