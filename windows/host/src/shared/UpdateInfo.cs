using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace SatoEdit {
  /// アップデートの確認のうち、Windows に依らない部分 (版の比べ方・GitHub Releases の答えの読み方・知らせるかどうかの決め方)。
  /// ネットからの取り寄せとインストーラーの起動は Updater.cs
  public static class UpdateInfo {
    /// 配布するインストーラーの名前 (GitHub に上げる名前は SatoruEditor-1.0.1-win-x64-setup.exe。大文字・小文字は問わない)
    public static readonly Regex AssetName = new Regex(@"^satorueditor-(\d+\.\d+\.\d+)-win-x64-setup\.exe$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    /// 自動で確かめる間隔 (ミリ秒)
    public const double Interval = 24 * 60 * 60 * 1000.0;

    /// "v1.2.3" → [1, 2, 3]。足りない所は 0、数字でない後ろ (-beta など) は無視する。読めなければ null
    public static int[] Parts(string version) {
      var s = (version ?? "").Trim();
      if (s.StartsWith("v", StringComparison.OrdinalIgnoreCase)) s = s.Substring(1);
      var m = Regex.Match(s, @"^(\d+)(?:\.(\d+))?(?:\.(\d+))?");
      if (!m.Success) return null;
      int P(Group g) => g.Success && int.TryParse(g.Value, out var n) ? n : 0;
      return new[] { P(m.Groups[1]), P(m.Groups[2]), P(m.Groups[3]) };
    }

    /// "1.2.3" の形にそろえる ("v1.2" → "1.2.0")。読めなければ ""
    public static string Normalize(string version) {
      var p = Parts(version);
      return p == null ? "" : string.Join(".", p);
    }

    /// a と b を x.y.z の数で比べる (a が新しければ正)。読めない版は、いちばん古いものとして扱う
    public static int Compare(string a, string b) {
      var pa = Parts(a) ?? new[] { -1, -1, -1 };
      var pb = Parts(b) ?? new[] { -1, -1, -1 };
      for (int i = 0; i < 3; i++) if (pa[i] != pb[i]) return pa[i] < pb[i] ? -1 : 1;
      return 0;
    }

    /// GitHub の releases/latest の答え → { status: "update" | "latest" | "noasset" | "error", version, current, notes, asset: { name, url, size } }
    public static JObj Parse(object release, string current) {
      var o = release as JObj;
      var tag = o?.Str("tag_name") ?? "";
      var version = Normalize(tag);
      var r = new JObj { { "current", current }, { "version", version }, { "tag", tag }, { "notes", o?.Str("html_url") ?? "" } };
      if (o == null || version == "") { r["status"] = "error"; r["message"] = "no release"; return r; }
      if (o.Bool("draft") || o.Bool("prerelease")) { r["status"] = "latest"; return r; } // 下書き・試験版は知らせない (latest はもともと返さない)
      if (Compare(version, current) <= 0) { r["status"] = "latest"; return r; }
      var assets = (o.Arr("assets") ?? new List<object>()).OfType<JObj>().ToList();
      // 同じ版の Windows 用インストーラー (無ければ、名前の形が合うもの)
      var asset = assets.FirstOrDefault(a => AssetName.Match(a.Str("name")) is Match m && m.Success && Normalize(m.Groups[1].Value) == version)
               ?? assets.FirstOrDefault(a => AssetName.IsMatch(a.Str("name")));
      if (asset == null || asset.Str("browser_download_url") == "") { r["status"] = "noasset"; return r; }
      r["status"] = "update";
      r["asset"] = new JObj { { "name", asset.Str("name") }, { "url", asset.Str("browser_download_url") }, { "size", asset.Num("size") } };
      return r;
    }

    /// 自動の確認では「この版はとばす」にした版は知らせない (自分で確かめたときは知らせる)
    public static JObj Decide(JObj result, bool auto, string skipVersion) {
      if (auto && result.Str("status") == "update" && skipVersion != "" && Normalize(skipVersion) == result.Str("version")) result["status"] = "skipped";
      return result;
    }

    /// 自動で確かめてよいか: "go" | "off" (設定で切ってある) | "notyet" (前に確かめてから 24 時間たっていない)
    public static string AutoGate(bool enabled, double lastCheck, double now) {
      if (!enabled) return "off";
      if (lastCheck > 0 && now - lastCheck < Interval && now >= lastCheck) return "notyet";
      return "go";
    }
  }
}
