using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace SatoEdit {
  /// 暗号化の鍵 (中身は画面側に渡さず、番号だけ渡す)
  partial class Bridge {
    readonly ConcurrentDictionary<string, FileCrypto.Key> keys = new ConcurrentDictionary<string, FileCrypto.Key>();
    readonly ConcurrentDictionary<string, byte[]> enrollments = new ConcurrentDictionary<string, byte[]>(); // ワンタイム認証の登録途中の秘密

    static readonly Dictionary<string, string> KindLabels = new Dictionary<string, string> {
      { "password", "パスワード" }, { "passcode", "パスコード" }, { "device", "この PC のロック" },
      { "totp", "ワンタイム認証" }, { "twoStep", "二段階" }, { "keyfile", "鍵ファイル" },
    };

    static string Hex(byte[] b) => BitConverter.ToString(b).Replace("-", "").ToLowerInvariant();

    string Keep(FileCrypto.Key key) {
      var token = Hex(Primitives.Random(12));
      keys[token] = key;
      return token;
    }

    /// { token, kind, label } (label は日本語。画面側で訳す)
    JObj EncInfo(FileCrypto.Key key) => new JObj { { "token", Keep(key) }, { "kind", key.Kind }, { "label", KindLabels.TryGetValue(key.Kind, out var l) ? l : key.Kind } };

    class DeviceRecord { public byte[] Raw, Totp; }

    static DeviceRecord GetDeviceRecord(byte[] id) {
      var raw = Store.GetSecret("key." + Hex(id));
      if (raw == null) return null;
      try {
        var o = (JObj)Json.Parse(raw);
        return new DeviceRecord { Raw = o.Str("raw") != "" ? Convert.FromBase64String(o.Str("raw")) : null, Totp = o.Str("totp") != "" ? Convert.FromBase64String(o.Str("totp")) : null };
      } catch { return null; }
    }

    static void StoreDeviceRecord(byte[] id, DeviceRecord rec) {
      var o = new JObj();
      if (rec.Raw != null) o["raw"] = Convert.ToBase64String(rec.Raw);
      if (rec.Totp != null) o["totp"] = Convert.ToBase64String(rec.Totp);
      Store.SetSecret("key." + Hex(id), Json.Stringify(o));
    }

    /// 鍵ファイルを探す: 前に使った場所と、つないであるドライブのいちばん上の階層
    static List<string> FindKeyFiles() {
      var dirs = new List<string>();
      var last = Store.Prefs.Str("lastKeyFileDir");
      if (last != "") dirs.Add(last);
      foreach (var letter in "DEFGHIJKLMNOPQRSTUVWXYZ") dirs.Add(letter + ":\\");
      var found = new List<string>();
      foreach (var d in dirs) {
        try {
          if (!Directory.Exists(d)) continue;
          foreach (var f in Directory.GetFiles(d)) {
            if (f.ToLowerInvariant().EndsWith("." + FileCrypto.KeyfileExtension)) found.Add(f);
          }
        } catch { }
      }
      return found;
    }

    static byte[] ReadKeyFile(string file) {
      try {
        if (new FileInfo(file).Length >= 4096) return null;
        return FileCrypto.KeyFileSecret(File.ReadAllBytes(file));
      } catch { return null; }
    }

    static void RememberKeyFileDir(string file) {
      Store.Prefs["lastKeyFileDir"] = Path.GetDirectoryName(file);
      Store.SavePrefsSoon();
    }

    /// 新しい鍵を用意する (暗号化して保存するとき)
    FileCrypto.Key MakeKey(JObj o) {
      var kind = o.Str("kind");
      var password = o["password"] as string;
      switch (kind) {
        case "password":
          if (password == null || password.Length < 8) throw new UserError("パスワードは 8 文字以上にしてください。");
          return FileCrypto.DeriveKey(password, "password");
        case "passcode":
          if (!System.Text.RegularExpressions.Regex.IsMatch(password ?? "", "^[0-9]{6,}$")) throw new UserError("パスコードは数字 6 桁以上にしてください。");
          return FileCrypto.DeriveKey(password, "passcode");
        case "device": {
          var k = FileCrypto.NewDeviceKey("device");
          StoreDeviceRecord(k.Salt, new DeviceRecord { Raw = k.Bytes });
          return k;
        }
        case "totp":
        case "twoStep": {
          if (!enrollments.TryGetValue(o.Str("enrollId"), out var secret)) throw new UserError("スマホの登録をやり直してください。");
          if (!Totp.Verify(o.Str("code"), secret)) throw new UserError("6 桁のコードが違います。スマホの認証アプリに出ている数字を入れてください。");
          FileCrypto.Key k;
          if (kind == "totp") {
            k = FileCrypto.NewDeviceKey("totp");
            StoreDeviceRecord(k.Salt, new DeviceRecord { Raw = k.Bytes, Totp = secret });
          } else {
            if (password == null || password.Length < 8) throw new UserError("パスワードは 8 文字以上にしてください。");
            k = FileCrypto.TwoStepKey(password, secret);
            StoreDeviceRecord(k.Salt, new DeviceRecord { Totp = secret });
          }
          enrollments.TryRemove(o.Str("enrollId"), out _);
          return k;
        }
        case "keyfile": {
          var secret = ReadKeyFile(o.Str("keyFile"));
          if (secret == null) throw new UserError("これは鍵ファイルではありません。");
          RememberKeyFileDir(o.Str("keyFile"));
          return FileCrypto.KeyFileKey(secret);
        }
        default:
          throw new UserError("暗号化の方法を選んでください。");
      }
    }

    class Unlocked { public string Need; public byte[] Plain; public FileCrypto.Key Key; }

    /// 暗号化ファイルを開く。足りないものがあれば Need を返して画面側で聞いてもらう
    Unlocked Unlock(byte[] buf, JObj creds) {
      var h = FileCrypto.ReadHeader(buf);
      var password = creds["password"] as string;
      var code = creds["code"] as string;
      switch (h.Kind) {
        case "password":
        case "passcode": {
          if (password == null) return new Unlocked { Need = h.Kind };
          var r = FileCrypto.OpenWithPassword(buf, password);
          return new Unlocked { Plain = r.Plain, Key = r.Key };
        }
        case "device": {
          var rec = GetDeviceRecord(h.Salt);
          if (rec == null || rec.Raw == null) throw FileCrypto.KeyNotHere();
          var key = FileCrypto.DeviceKey(rec.Raw, h.Salt, "device");
          return new Unlocked { Plain = FileCrypto.Open(buf, key), Key = key };
        }
        case "totp": {
          var rec = GetDeviceRecord(h.Salt);
          if (rec == null || rec.Raw == null || rec.Totp == null) throw FileCrypto.KeyNotHere();
          if (code == null) return new Unlocked { Need = "totp" };
          if (!Totp.Verify(code, rec.Totp)) throw new FileCrypto.CryptoError("wrongCode", "6 桁のコードが違います。");
          var key = FileCrypto.DeviceKey(rec.Raw, h.Salt, "totp");
          return new Unlocked { Plain = FileCrypto.Open(buf, key), Key = key };
        }
        case "twoStep": {
          var rec = GetDeviceRecord(h.Salt);
          if (rec == null || rec.Totp == null) throw FileCrypto.KeyNotHere();
          if (password == null || code == null) return new Unlocked { Need = "twoStep" };
          if (!Totp.Verify(code, rec.Totp)) throw new FileCrypto.CryptoError("wrongCode", "6 桁のコードが違います。");
          var r = FileCrypto.OpenTwoStep(buf, password, rec.Totp);
          return new Unlocked { Plain = r.Plain, Key = r.Key };
        }
        case "keyfile": {
          var given = creds.Str("keyFile");
          var candidates = given != "" ? new List<string> { given } : FindKeyFiles();
          foreach (var f in candidates) {
            var secret = ReadKeyFile(f);
            if (secret == null || FileCrypto.KeyFileFingerprint(secret) != h.Iterations) continue;
            RememberKeyFileDir(f);
            var r = FileCrypto.OpenWithKeyFile(buf, secret);
            return new Unlocked { Plain = r.Plain, Key = r.Key };
          }
          if (given != "") throw FileCrypto.WrongKeyFile();
          return new Unlocked { Need = "keyfile" };
        }
        default:
          throw FileCrypto.UnsupportedVersion();
      }
    }

    void RegisterCrypto() {
      On("totpBegin", a => {
        var secret = Totp.NewSecret();
        var id = Hex(Primitives.Random(8));
        enrollments[id] = secret;
        var account = S(a, 0);
        return new JObj { { "enrollId", id }, { "base32", Totp.Base32(secret) }, { "uri", Totp.Uri(secret, account == "" ? "document" : account, S(a, 1, "satoEdit")) } };
      });
      OnBg("makeKey", a => {
        try {
          var key = MakeKey(O(a, 0));
          Store.Prefs["encDefaultKind"] = key.Kind;
          Store.SavePrefsSoon();
          return new JObj { { "status", "ok" }, { "enc", EncInfo(key) } };
        } catch (Exception e) { return Fail(e); }
      });
      OnAsync("newKeyFile", async a => {
        var o = O(a, 0);
        await Task.Yield();
        var file = Dialogs.Save(form, new JObj { { "title", o.Str("title") }, { "defaultPath", "satoru-editor-key." + FileCrypto.KeyfileExtension }, { "filters", o.Arr("filters") } });
        if (file == null) return null;
        using (var fs = new FileStream(file, FileMode.CreateNew)) { // すでにある鍵ファイルは上書きしない
          var data = FileCrypto.NewKeyFileContents();
          fs.Write(data, 0, data.Length);
        }
        return file;
      });
    }
  }
}
