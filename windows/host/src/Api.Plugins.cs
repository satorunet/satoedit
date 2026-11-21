using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Web.WebView2.Core;

namespace SatoEdit {
  /// JS 拡張機能のファイルまわり (core/plugins.js と同じ)。manifest の中身を確かめるのは画面側 (shared/pluginmanifest.js)。
  /// 拡張機能の Worker からの satoplug://call/ (同期の命令) と satoplug://fetch/ (ネット) もここで受ける
  partial class Bridge {
    static string PluginsDir => Path.Combine(Store.ConfigDir, "plugins");
    readonly ConcurrentDictionary<string, List<Zip.Entry>> pluginStaging = new ConcurrentDictionary<string, List<Zip.Entry>>();
    readonly ConcurrentDictionary<string, string> pluginTokens = new ConcurrentDictionary<string, string>(); // 合言葉 (Worker ごと) → 拡張機能の id
    readonly ConcurrentDictionary<int, TaskCompletionSource<object>> pluginPending = new ConcurrentDictionary<int, TaskCompletionSource<object>>();
    int pluginSeq;

    static bool Inside(string path, string folder) {
      var full = Path.GetFullPath(path);
      var root = Path.GetFullPath(folder).TrimEnd('\\') + "\\";
      return full.StartsWith(root, StringComparison.OrdinalIgnoreCase);
    }

    /// 入っている拡張機能の生の中身: [{ folder, manifestText, source, iconData, error }]
    static List<object> PluginRaw() {
      var outl = new List<object>();
      if (!Directory.Exists(PluginsDir)) return outl;
      foreach (var folder in Directory.GetDirectories(PluginsDir).OrderBy(x => Path.GetFileName(x), StringComparer.Ordinal)) {
        if (Path.GetFileName(folder).StartsWith(".")) continue;
        string text;
        try { text = File.ReadAllText(Path.Combine(folder, "manifest.json"), Encoding.UTF8); } catch { continue; }
        var e = new JObj { { "folder", folder }, { "manifestText", text }, { "source", "" }, { "error", null } };
        var m = Json.TryParse(text) as JObj;
        var main = m?.Str("main", "main.js") ?? "main.js";
        try {
          // フォルダの外 (リンクの先など) は読まない
          var mainPath = Path.Combine(folder, main.Replace('/', '\\'));
          if (!Inside(mainPath, folder) || (new FileInfo(mainPath).Attributes & FileAttributes.ReparsePoint) != 0) throw new Exception(main + " outside");
          e["source"] = File.ReadAllText(mainPath, Encoding.UTF8);
        } catch (Exception ex) { e["error"] = ex.Message; }
        var icon = m?.Str("icon") ?? "";
        if (icon.Contains(".") && !icon.Contains("..")) {
          try {
            var ip = Path.Combine(folder, icon.Replace('/', '\\'));
            if (Inside(ip, folder)) e["iconData"] = Convert.ToBase64String(File.ReadAllBytes(ip));
          } catch { }
        }
        outl.Add(e);
      }
      return outl;
    }

    static JObj FindPluginManifest(string id) {
      foreach (var r in PluginRaw().OfType<JObj>()) {
        if (Json.TryParse(r.Str("manifestText")) is JObj m && m.Str("id") == id) return m;
      }
      return null;
    }

    /// manifest.json のある所 (そのもの、または 1 段下。GitHub の zip は repo-main/ の下に入っている)
    static string FindRoot(List<Zip.Entry> files) {
      var names = files.Select(f => f.Name).ToList();
      if (names.Contains("manifest.json")) return "";
      foreach (var top in names.Where(n => !n.StartsWith("__MACOSX/")).Select(n => n.Split('/')[0] + "/").Distinct()) {
        if (names.Contains(top + "manifest.json")) return top;
      }
      return null;
    }

    /// 拡張機能の satoru.fetch (network の権限があるときだけ) → { status, headers, body }
    static async Task<JObj> PluginFetch(string id, string url, JObj opts) {
      var m = FindPluginManifest(id);
      if (m == null || !(m.Arr("permissions") ?? new List<object>()).OfType<string>().Contains("network")) throw new UserError("no network permission");
      if (!Uri.TryCreate(url, UriKind.Absolute, out var u) || (u.Scheme != "http" && u.Scheme != "https")) throw new UserError("bad URL");
      var o = new JObj { { "url", u.ToString() }, { "method", opts.Str("method", "GET") }, { "headers", opts.Obj("headers") ?? new JObj() }, { "timeout", 30000.0 } };
      if (opts["body"] is string b) o["body"] = b;
      return await HttpOnce(o, 10L * 1024 * 1024);
    }

    void RegisterPlugins() {
      OnBg("pluginRaw", a => PluginRaw());
      On("pluginsFolder", a => { Directory.CreateDirectory(PluginsDir); return PluginsDir; });
      OnAsync("pluginStage", async a => {
        var o = O(a, 0);
        List<Zip.Entry> files;
        if (o.Str("url") != "") {
          var r = await HttpOnce(new JObj { { "url", o.Str("url") }, { "timeout", 30000.0 } }, 20L * 1024 * 1024, true);
          if (r.Num("status") != 200) throw new UserError("HTTP " + r.Num("status"));
          files = await Task.Run(() => Zip.Extract(BodyBytes(r)));
        } else {
          var p = o.Str("path");
          files = await Task.Run(() => {
            if (Directory.Exists(p)) {
              var list = new List<Zip.Entry>();
              void Walk(string dir, string rel) {
                foreach (var e in new DirectoryInfo(dir).GetFileSystemInfos()) {
                  if (e.Name.StartsWith(".")) continue;
                  var r = rel == "" ? e.Name : rel + "/" + e.Name;
                  if ((e.Attributes & FileAttributes.Directory) != 0) Walk(e.FullName, r);
                  else list.Add(new Zip.Entry { Name = r, Data = File.ReadAllBytes(e.FullName) });
                  if (list.Count > 2000) throw new UserError("too many files");
                }
              }
              Walk(p, "");
              return list;
            }
            return Zip.Extract(File.ReadAllBytes(p));
          });
        }
        var root = FindRoot(files);
        if (root == null) throw new UserError("noManifest");
        var inside = files.Where(f => f.Name.StartsWith(root) && !f.Name.StartsWith("__MACOSX/")).Select(f => new Zip.Entry { Name = f.Name.Substring(root.Length), Data = f.Data }).ToList();
        var token = "p" + DateTime.Now.Ticks.ToString("x") + Hex(Primitives.Random(3));
        pluginStaging[token] = inside;
        var mf = inside.First(f => f.Name == "manifest.json");
        return new JObj { { "token", token }, { "manifestText", Encoding.UTF8.GetString(mf.Data) }, { "files", inside.Select(f => (object)f.Name).ToList() } };
      });
      On("pluginDiscard", a => { pluginStaging.TryRemove(S(a, 0), out _); return true; });
      OnBg("pluginCommit", a => {
        if (!pluginStaging.TryRemove(S(a, 0), out var files)) throw new UserError("expired");
        var id = S(a, 1);
        if (!System.Text.RegularExpressions.Regex.IsMatch(id, "^[a-z0-9][a-z0-9._-]{0,63}$")) throw new UserError("badID: " + id);
        Directory.CreateDirectory(PluginsDir);
        var dest = Path.Combine(PluginsDir, id);
        // 前のものはごみ箱へ
        foreach (var old in (Arg(a, 2) as List<object> ?? new List<object>()).OfType<string>().Concat(new[] { dest }).Distinct()) {
          if (Inside(old, PluginsDir) && (Directory.Exists(old) || File.Exists(old))) Win32.Trash(old);
        }
        foreach (var f in files) {
          var target = Path.Combine(dest, f.Name.Replace('/', '\\'));
          if (!Inside(target, dest)) throw new UserError("unsafe path");
          Directory.CreateDirectory(Path.GetDirectoryName(target));
          File.WriteAllBytes(target, f.Data);
        }
        return dest;
      });
      On("trashPath", a => {
        var p = S(a, 0);
        if (!Inside(p, PluginsDir)) throw new UserError("outside plugins");
        Win32.Trash(p);
        return true;
      });
      OnBg("pluginTemplate", a => {
        var id = S(a, 0);
        var dir = Path.Combine(PluginsDir, id);
        if (!Inside(dir, PluginsDir)) throw new UserError("badID: " + id);
        if (Directory.Exists(dir)) throw new UserError("exists");
        Directory.CreateDirectory(dir);
        var utf8 = new UTF8Encoding(false);
        File.WriteAllText(Path.Combine(dir, "manifest.json"), S(a, 1), utf8);
        File.WriteAllText(Path.Combine(dir, "main.js"), S(a, 2), utf8);
        File.WriteAllText(Path.Combine(PluginsDir, "README.md"), S(a, 3), utf8);
        return Path.Combine(dir, "main.js");
      });
      OnBg("pluginDocs", a => {
        Directory.CreateDirectory(PluginsDir);
        var p = Path.Combine(PluginsDir, "README.md");
        File.WriteAllText(p, S(a, 0), new UTF8Encoding(false));
        return p;
      });
      OnAsync("pluginFetch", async a => await PluginFetch(S(a, 0), S(a, 1), O(a, 2)));
      On("pluginToken", a => {
        var token = S(a, 0);
        var id = S(a, 1);
        if (id != "") pluginTokens[token] = id; else pluginTokens.TryRemove(token, out _);
        return true;
      });
      On("pluginReply", a => {
        if (!pluginPending.TryRemove((int)N(a, 0), out var p)) return false;
        if (B(a, 1)) p.TrySetResult(Arg(a, 2)); else p.TrySetException(new UserError(S(a, 2)));
        return true;
      });
    }

    static byte[] BodyBytes(JObj r) => r["bodyBytes"] as byte[] ?? Encoding.UTF8.GetBytes(r.Str("body"));

    /// satoplug:// を受ける。答えが決まるまで Worker は待っている (同期の XMLHttpRequest)
    public void StartPluginScheme() {
      Web.AddWebResourceRequestedFilter("satoplug://*", CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
      Web.WebResourceRequested += async (s, e) => {
        if (!e.Request.Uri.StartsWith("satoplug:", StringComparison.OrdinalIgnoreCase)) return;
        var deferral = e.GetDeferral();
        try {
          var cors = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Content-Type\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nContent-Type: application/json";
          CoreWebView2WebResourceResponse Reply(int status, string reason, string body) =>
            form.Env.CreateWebResourceResponse(new MemoryStream(Encoding.UTF8.GetBytes(body)), status, reason, cors);
          if (e.Request.Method == "OPTIONS") { e.Response = Reply(204, "No Content", ""); return; }
          JObj msg = null;
          try {
            var content = e.Request.Content;
            if (content != null) msg = Json.Parse(new StreamReader(content, Encoding.UTF8).ReadToEnd()) as JObj;
          } catch { }
          if (msg == null) { e.Response = Reply(400, "Bad Request", "{\"error\":\"bad request\"}"); return; }
          if (!pluginTokens.TryGetValue(msg.Str("token"), out var id)) { e.Response = Reply(403, "Forbidden", "{\"error\":\"unknown plugin\"}"); return; }
          object value;
          try {
            if (new Uri(e.Request.Uri).Host == "fetch") {
              value = await PluginFetch(id, msg.Str("url"), msg.Obj("opts") ?? new JObj());
            } else {
              // 画面側で、いまの文書に対して行ってもらう
              var reqId = System.Threading.Interlocked.Increment(ref pluginSeq);
              var tcs = new TaskCompletionSource<object>();
              pluginPending[reqId] = tcs;
              Send("plugin:call", (double)reqId, id, msg.Str("op"), msg.Arr("args") ?? new List<object>());
              value = await tcs.Task;
            }
            e.Response = Reply(200, "OK", Json.Stringify(new JObj { { "value", value } }));
          } catch (Exception ex) {
            e.Response = Reply(200, "OK", Json.Stringify(new JObj { { "error", ex.Message } }));
          }
        } catch (Exception ex) {
          Log.Error("satoplug", ex);
        } finally {
          deferral.Complete();
        }
      };
    }
  }
}
