using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace SatoEdit {
  /// 設定ファイル (~/.satoruEditor。前の名前は ~/.sakubunEditor・~/.satomaru) と、秘密の置き場。Electron 版と同じ場所・同じ形なので、設定はそのまま引き継がれる
  static class Store {
    public static readonly string Home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    public static readonly string ConfigDir = Path.Combine(Home, ".satoruEditor");
    /// 前の名前 (新しいものから順に)
    static readonly string[] OldConfigDirs = { Path.Combine(Home, ".sakubunEditor"), Path.Combine(Home, ".satomaru") };

    /// 前の名前の設定フォルダ (~/.satomaru) があり、新しいほうがまだ無ければ、名前を変えて移す (main.js と同じ)
    public static void MigrateConfigDir() {
      try {
        if (Directory.Exists(ConfigDir)) return;
        foreach (var old in OldConfigDirs) {
          if (!Directory.Exists(old)) continue;
          Directory.Move(old, ConfigDir);
          return;
        }
      } catch (Exception e) { Log.Error("migrate", e); } // 移せないときは新しく作る
    }
    public static string F(string name) => Path.Combine(ConfigDir, name);
    public static string PrefsFile => F("prefs.json");
    public static string ThemeFile => F("theme.json");
    public static string ProfilesFile => F("profiles.json");
    public static string UsageFile => F("ai-usage.json");
    public static string KnownHostsFile => F("known-hosts.json");
    public static string PricesFile => F("ai-prices.json");
    /// 軽量版の秘密 (Windows のログインに結び付けて DPAPI で暗号化)。Electron 版の secrets.json とは別のファイル
    public static string SecretsFile => F("secrets-win.json");
    /// Electron 版が使っていた秘密 (読むだけ。見つからないものはこちらも探す)
    public static string LegacySecretsFile => F("secrets.json");

    // 動作環境の設定値 (main.js の PREF_DEFAULTS と同じ。新規ファイルの改行だけ Windows に合わせて CRLF)
    const string PrefDefaultsJson = @"{
  ""wrap"": true, ""invisibles"": true, ""lineNumbers"": true, ""columnRuler"": true, ""toolbar"": true,
  ""showEOF"": true, ""highlightCurrentLine"": true, ""autoIndent"": true, ""codeCompletion"": true, ""rememberCaret"": true,
  ""defaultEncoding"": ""utf8"", ""defaultLineEnding"": ""crlf"",
  ""backupOnSave"": false, ""trimTrailingOnSave"": false,
  ""encryptAlways"": false, ""aiEnabled"": true, ""encryptionEnabled"": false, ""paperEnabled"": true, ""folderTreeEnabled"": false,
  ""lineCounting"": ""logical"", ""lineSpacing"": 2, ""genkoFullWidth"": false, ""genkoFurigana"": true, ""genkoAutoIndent"": true, ""genkoHorizontal"": false, ""startPaperMode"": ""last"", ""lastPaperMode"": ""genko"", ""genkoAutoFormat"": true, ""a4AutoFormat"": true, ""linkURLs"": true, ""paperSavePDF"": true,
  ""encDefaultKind"": ""device"", ""aiProvider"": ""openai"", ""aiModels"": {}, ""aiCustomBaseURL"": ""http://localhost:11434/v1"", ""aiVerified"": {},
  ""folderTreeVisible"": false, ""folderTreeRoot"": """", ""folderTreeWidth"": 240, ""aiVisible"": false, ""diffVisible"": false, ""remotePlaces"": {}, ""remoteTreeVisible"": false, ""remoteTreeWidth"": 260, ""pluginsDisabled"": [], ""pluginSources"": {}, ""pluginStorage"": {}, ""diffWidth"": 360, ""aiWidth"": 340, ""iconColor"": ""ai"",
  ""recent"": [], ""carets"": {}, ""lastKeyFileDir"": """", ""windowBounds"": null, ""language"": ""auto"",
  ""collabEnabled"": false, ""collabChatVisible"": true, ""collabPort"": 7650, ""collabName"": """", ""aiApply"": ""confirm"", ""keys"": {}, ""hiddenMenu"": [], ""toolbarItems"": null, ""servers"": [], ""serverEnabled"": false, ""remoteAutoUpload"": true, ""aiPrices"": {}, ""aiYenPerDollar"": 150,
  ""libraryEnabled"": true, ""libraryVisible"": true, ""libraryFiles"": [], ""librarySeeded"": false, ""libraryPinned"": [], ""libraryModes"": {}, ""libraryFolderIcons"": {}, ""libraryFolderOrder"": [],
  ""librarySelectedGroup"": ""all"", ""libraryFolderExpanded"": [], ""libraryListWidth"": 220, ""libraryFolderWidth"": 140, ""libraryOneColumn"": true,
  ""paperCandidates"": null,
  ""versionHistory"": true, ""versionHistoryMax"": 20,
  ""shareEnabled"": true, ""sharedLinks"": [], ""shareVisibility"": ""unlisted"", ""shareDays"": 30, ""shareKeepHistory"": true, ""sharePrivacyCheckOff"": false
}";
    public static readonly JObj PrefDefaults = (JObj)Json.Parse(PrefDefaultsJson);

    /// 「すべて初期状態に戻す」でも消さない、自分のデータ (Mac 版と同じ: AI の鍵・サーバの一覧・テキストの一覧・公開中のリンクなど)
    public static readonly HashSet<string> KeepOnReset = new HashSet<string> {
      "recent", "carets", "windowBounds", "lastKeyFileDir", "servers", "remotePlaces", "folderTreeRoot",
      "libraryFiles", "librarySeeded", "libraryPinned", "libraryModes", "libraryFolderIcons", "libraryFolderOrder", "sharedLinks",
      "aiVerified", "aiPrices", "pluginsDisabled", "pluginSources", "pluginStorage", "collabName", "toolbarItems",
    };

    /// すべての設定を最初の状態に戻す (自分のデータは残す)。色・フォントとファイルタイプ別の設定も消す
    public static void ResetPrefs() {
      lock (prefsLock) {
        foreach (var k in PrefDefaults.Keys.ToList()) if (!KeepOnReset.Contains(k)) Prefs[k] = Json.Parse(Json.Stringify(PrefDefaults[k]));
      }
      SavePrefsNow();
      try { File.Delete(ThemeFile); } catch { }
      try { File.Delete(ProfilesFile); } catch { }
    }
    public static JObj Prefs = PrefDefaults.Clone();

    public static string ReadText(string file) {
      try { return File.ReadAllText(file, new UTF8Encoding(false)); } catch { return null; }
    }

    public static object ReadJSON(string file, object fallback) {
      var s = ReadText(file);
      if (s == null) return fallback;
      return Json.TryParse(s, fallback);
    }

    /// 書きかけのファイルが残らないよう、別の名前で書いてから置き換える
    public static void WriteAtomic(string file, byte[] data) {
      var dir = Path.GetDirectoryName(Path.GetFullPath(file));
      Directory.CreateDirectory(dir);
      var tmp = file + ".tmp-" + System.Diagnostics.Process.GetCurrentProcess().Id;
      File.WriteAllBytes(tmp, data);
      try {
        Win32.ReplaceFile(tmp, file);
      } catch {
        try { File.Delete(tmp); } catch { }
        throw;
      }
    }
    public static void WriteAtomic(string file, string text) => WriteAtomic(file, new UTF8Encoding(false).GetBytes(text));

    public static void LoadPrefs() {
      var saved = ReadJSON(PrefsFile, null) as JObj;
      Prefs = PrefDefaults.Clone();
      if (saved != null) foreach (var kv in saved) Prefs[kv.Key] = kv.Value;
      // この版より前の設定 (テキスト管理がまだ無かったころ): 用紙切替・ふりがなを Mac 版と同じ「オン」から始める
      if (saved != null && !saved.Has("libraryEnabled")) { Prefs["paperEnabled"] = true; Prefs["genkoFurigana"] = true; }
      // Mac 版と同じ: 共同編集は (いまは) 使わないので、前にオンにしていてもオフ
      Prefs["collabEnabled"] = false;
      Prefs["folderTreeEnabled"] = false; // フォルダツリーはテキスト一覧と重なるので出さない (Mac 版と同じ)
    }

    static System.Threading.Timer prefsTimer;
    static readonly object prefsLock = new object();
    public static void SavePrefsSoon() {
      lock (prefsLock) {
        prefsTimer?.Dispose();
        prefsTimer = new System.Threading.Timer(_ => SavePrefsNow(), null, 300, System.Threading.Timeout.Infinite);
      }
    }
    public static void SavePrefsNow() {
      string text;
      lock (prefsLock) {
        prefsTimer?.Dispose();
        prefsTimer = null;
        text = Json.Pretty(Prefs);
      }
      try { WriteAtomic(PrefsFile, text); } catch (Exception e) { Log.Error("prefs", e); } // 書けなくても編集は続けられる
    }

    // ---------- 秘密の置き場 ----------

    static readonly byte[] Entropy = Encoding.UTF8.GetBytes("satoedit-secrets-v1");

    public static bool SecretsAvailable => true; // DPAPI はいつでも使える

    public static string GetSecret(string name) {
      var all = ReadJSON(SecretsFile, null) as JObj ?? new JObj();
      if (all.Has(name)) {
        if (!(all[name] is string v) || v == "") return null; // 消した印
        try { return Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(v), Entropy, DataProtectionScope.CurrentUser)); } catch { return null; }
      }
      return LegacySecret(name);
    }

    public static void SetSecret(string name, string value) {
      var all = ReadJSON(SecretsFile, null) as JObj ?? new JObj();
      if (string.IsNullOrEmpty(value)) {
        all[name] = null; // Electron 版に残っているものを読み直さないように、消した印を残す
      } else {
        all[name] = Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(value), Entropy, DataProtectionScope.CurrentUser));
      }
      WriteAtomic(SecretsFile, Json.Pretty(all));
    }

    /// Electron 版 (safeStorage) が書いた秘密を読む。鍵は %APPDATA%\satoruEditor (前は satoedit)\Local State に DPAPI で守られて入っている
    static byte[] legacyKey;
    static bool legacyKeyTried;
    static string LegacySecret(string name) {
      try {
        var all = ReadJSON(LegacySecretsFile, null) as JObj;
        if (all == null || !(all[name] is string v) || v == "") return null;
        var data = Convert.FromBase64String(v);
        if (!legacyKeyTried) {
          legacyKeyTried = true;
          var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
          var ls = (ReadJSON(Path.Combine(appData, "satoruEditor", "Local State"), null) ?? ReadJSON(Path.Combine(appData, "sakubunEditor", "Local State"), null) ?? ReadJSON(Path.Combine(appData, "satoedit", "Local State"), null)) as JObj;
          var enc = ls?.Obj("os_crypt")?.Str("encrypted_key");
          if (!string.IsNullOrEmpty(enc)) {
            var raw = Convert.FromBase64String(enc);
            if (raw.Length > 5 && Encoding.ASCII.GetString(raw, 0, 5) == "DPAPI") {
              legacyKey = ProtectedData.Unprotect(raw.Skip(5).ToArray(), null, DataProtectionScope.CurrentUser);
            }
          }
        }
        if (data.Length > 3 + 12 + 16 && Encoding.ASCII.GetString(data, 0, 3) == "v10" && legacyKey != null) {
          var nonce = data.Skip(3).Take(12).ToArray();
          var tag = data.Skip(data.Length - 16).ToArray();
          var body = data.Skip(15).Take(data.Length - 15 - 16).ToArray();
          return Encoding.UTF8.GetString(Primitives.GcmDecrypt(legacyKey, nonce, body, new byte[0], tag));
        }
        // 古い形 (鍵なしで DPAPI だけ)
        return Encoding.UTF8.GetString(ProtectedData.Unprotect(data, null, DataProtectionScope.CurrentUser));
      } catch {
        return null;
      }
    }
  }
}
