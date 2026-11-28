using System;
using System.Linq;
using System.Text;

namespace SatoEdit {
  /// 流出防止のためのファイル暗号化 (AES-256-GCM)。core/filecrypto.js・Mac 版 FileCrypto.swift と同じファイルの形。
  ///   "SATORU-ENC\n" | 版=2 | 種類 (1) | 繰り返し回数 (4) | ソルト または 鍵の番号 (16) | AES-GCM (nonce 12 + 暗号文 + タグ 16)
  /// 版 1 (種類なし = パスワード) のファイルも読める。先頭部分も改ざん検出の対象
  public static class FileCrypto {
    public static readonly byte[] Magic = Encoding.UTF8.GetBytes("SATORU-ENC\n");
    public const int Version = 2;
    public const int DefaultIterations = 600000;
    public const int PasscodeIterations = 2000000;
    public static readonly string[] KindNames = { "password", "passcode", "device", "totp", "keyfile", "twoStep" };
    public const string KeyfileHeader = "SATORU-KEYFILE-1";
    public const string KeyfileExtension = "satorukey";

    public class Key { public byte[] Bytes, Salt; public uint Iterations; public string Kind; }

    public class CryptoError : Exception {
      public string Code;
      public CryptoError(string code, string message) : base(message) { Code = code; }
    }
    // メッセージは日本語のまま。画面側 (host.js) が i18n で訳す
    public static CryptoError NotEncrypted() => new CryptoError("notEncrypted", "暗号化されたファイルではありません");
    public static CryptoError UnsupportedVersion() => new CryptoError("unsupportedVersion", "このアプリでは読めない新しい形式の暗号化ファイルです");
    public static CryptoError Wrong() => new CryptoError("wrong", "パスワード (パスコード) が違うか、ファイルが壊れています");
    public static CryptoError WrongKeyFile() => new CryptoError("wrongKeyFile", "この文書を暗号化したときの鍵ファイルではありません");
    public static CryptoError KeyNotHere() => new CryptoError("keyNotHere", "このファイルの鍵はこの PC にありません。暗号化した PC でしか開けません。");

    static int KindIndex(string kind) => Array.IndexOf(KindNames, kind);

    public static bool IsEncrypted(byte[] buf) {
      if (buf.Length <= Magic.Length) return false;
      for (int i = 0; i < Magic.Length; i++) if (buf[i] != Magic[i]) return false;
      return true;
    }

    /// パスワード (またはパスコード) から鍵を作る (少し時間がかかる)。salt を省くと新しく作る
    public static Key DeriveKey(string password, string kind = "password", byte[] salt = null, uint iterations = 0) {
      if (iterations == 0) iterations = (uint)(kind == "passcode" ? PasscodeIterations : DefaultIterations);
      salt = salt ?? Primitives.Random(16);
      return new Key { Bytes = Primitives.Pbkdf2(Encoding.UTF8.GetBytes(password), salt, (int)iterations), Salt = salt, Iterations = iterations, Kind = kind };
    }

    /// この PC 用の乱数の鍵 (保存は本体側で、Windows のログインに結び付けて行う)
    public static Key NewDeviceKey(string kind = "device") => new Key { Bytes = Primitives.Random(32), Salt = Primitives.Random(16), Iterations = 0, Kind = kind };

    public static Key DeviceKey(byte[] raw, byte[] id, string kind = "device") => new Key { Bytes = raw, Salt = id, Iterations = 0, Kind = kind };

    /// 二段階: パスワードから作った鍵に、認証アプリと共有している秘密を混ぜる
    public static Key TwoStepKey(string password, byte[] totpSecret, byte[] salt = null, uint iterations = 0) {
      var b = DeriveKey(password, "password", salt, iterations == 0 ? DefaultIterations : iterations);
      return new Key { Bytes = Primitives.Hkdf(b.Bytes, totpSecret, Encoding.UTF8.GetBytes("satoru-two-step")), Salt = b.Salt, Iterations = b.Iterations, Kind = "twoStep" };
    }

    // 鍵ファイル
    public static byte[] NewKeyFileContents() =>
      Encoding.UTF8.GetBytes(KeyfileHeader + "\n# satoEdit key file. If you lose it, documents encrypted with it can never be opened.\n"
        + Convert.ToBase64String(Primitives.Random(32)) + "\n");

    /// 鍵ファイルの中身から元の乱数を取り出す。鍵ファイルでなければ null
    public static byte[] KeyFileSecret(byte[] contents) {
      if (contents.Length >= 4096) return null;
      string text;
      try { text = new UTF8Encoding(false, false).GetString(contents); } catch { return null; }
      var lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n').Select(s => s.Trim(' ', '\t', '　', '﻿', '\v', '\f')).Where(s => s.Length > 0).ToList();
      if (lines.Count == 0 || lines[0] != KeyfileHeader) return null;
      var line = lines.Skip(1).FirstOrDefault(s => !s.StartsWith("#", StringComparison.Ordinal));
      if (line == null || !System.Text.RegularExpressions.Regex.IsMatch(line, "^[A-Za-z0-9+/]+=*$")) return null;
      byte[] secret;
      try { secret = Convert.FromBase64String(line); } catch { return null; }
      return secret.Length == 32 ? secret : null;
    }

    /// 鍵ファイルの指紋 (暗号化ファイルの先頭に入れて、違う鍵ファイルをすぐ見分ける)
    public static uint KeyFileFingerprint(byte[] secret) {
      var label = Encoding.UTF8.GetBytes("satoru-keyfile-id");
      var d = Primitives.Sha256(label.Concat(secret).ToArray());
      return ((uint)d[0] << 24) | ((uint)d[1] << 16) | ((uint)d[2] << 8) | d[3];
    }

    public static Key KeyFileKey(byte[] secret, byte[] salt = null) {
      salt = salt ?? Primitives.Random(16);
      return new Key { Bytes = Primitives.Hkdf(secret, salt, Encoding.UTF8.GetBytes("satoru-file-key")), Salt = salt, Iterations = KeyFileFingerprint(secret), Kind = "keyfile" };
    }

    public static byte[] HeaderData(Key key, int version = Version) {
      var h = new System.IO.MemoryStream();
      h.Write(Magic, 0, Magic.Length);
      h.WriteByte((byte)version);
      if (version >= 2) h.WriteByte((byte)KindIndex(key.Kind));
      var it = key.Iterations;
      h.WriteByte((byte)(it >> 24)); h.WriteByte((byte)(it >> 16)); h.WriteByte((byte)(it >> 8)); h.WriteByte((byte)it);
      h.Write(key.Salt, 0, key.Salt.Length);
      return h.ToArray();
    }

    /// 平文 → 暗号化ファイルの中身 (保存のたびに nonce は新しくなる)
    public static byte[] Seal(byte[] plain, Key key, int version = Version) {
      var h = HeaderData(key, version);
      var nonce = Primitives.Random(12);
      var tag = new byte[16];
      var body = Primitives.GcmEncrypt(key.Bytes, nonce, plain, h, tag);
      var o = new byte[h.Length + 12 + body.Length + 16];
      Buffer.BlockCopy(h, 0, o, 0, h.Length);
      Buffer.BlockCopy(nonce, 0, o, h.Length, 12);
      Buffer.BlockCopy(body, 0, o, h.Length + 12, body.Length);
      Buffer.BlockCopy(tag, 0, o, h.Length + 12 + body.Length, 16);
      return o;
    }

    public class Header { public int Version; public string Kind; public uint Iterations; public byte[] Salt; public int Length; }

    /// ファイルの先頭を読む
    public static Header ReadHeader(byte[] buf) {
      if (!IsEncrypted(buf)) throw NotEncrypted();
      int v = buf[Magic.Length];
      int i = Magic.Length + 1;
      string kind;
      if (v == 1) {
        kind = "password";
      } else if (v == 2) {
        if (buf.Length <= i || buf[i] >= KindNames.Length) throw UnsupportedVersion();
        kind = KindNames[buf[i]];
        i += 1;
      } else {
        throw UnsupportedVersion();
      }
      if (buf.Length < i + 20) throw Wrong();
      uint it = ((uint)buf[i] << 24) | ((uint)buf[i + 1] << 16) | ((uint)buf[i + 2] << 8) | buf[i + 3];
      var salt = new byte[16];
      Buffer.BlockCopy(buf, i + 4, salt, 0, 16);
      return new Header { Version = v, Kind = kind, Iterations = it, Salt = salt, Length = i + 20 };
    }

    /// 暗号化ファイル → 平文
    public static byte[] Open(byte[] buf, Key key) {
      var h = ReadHeader(buf);
      if (buf.Length < h.Length + 28 || !Primitives.Equal(h.Salt, key.Salt) || h.Kind != key.Kind) throw Wrong();
      try {
        var aad = new byte[h.Length];
        Buffer.BlockCopy(buf, 0, aad, 0, h.Length);
        var nonce = new byte[12];
        Buffer.BlockCopy(buf, h.Length, nonce, 0, 12);
        var tag = new byte[16];
        Buffer.BlockCopy(buf, buf.Length - 16, tag, 0, 16);
        var body = new byte[buf.Length - h.Length - 28];
        Buffer.BlockCopy(buf, h.Length + 12, body, 0, body.Length);
        return Primitives.GcmDecrypt(key.Bytes, nonce, body, aad, tag);
      } catch {
        throw Wrong();
      }
    }

    static void CheckIterations(Header h) {
      // 極端な回数を書き込まれたファイルで固まらないように
      if (h.Iterations < 10000 || h.Iterations > 50000000) throw Wrong();
    }

    public class Opened { public byte[] Plain; public Key Key; }

    /// パスワード・パスコードで開く (鍵も返すので、保存のときに使い回せる)
    public static Opened OpenWithPassword(byte[] buf, string password) {
      var h = ReadHeader(buf);
      if (h.Kind != "password" && h.Kind != "passcode") throw Wrong();
      CheckIterations(h);
      var key = DeriveKey(password, h.Kind, h.Salt, h.Iterations);
      return new Opened { Plain = Open(buf, key), Key = key };
    }

    public static Opened OpenTwoStep(byte[] buf, string password, byte[] totpSecret) {
      var h = ReadHeader(buf);
      if (h.Kind != "twoStep") throw Wrong();
      CheckIterations(h);
      var key = TwoStepKey(password, totpSecret, h.Salt, h.Iterations);
      return new Opened { Plain = Open(buf, key), Key = key };
    }

    public static Opened OpenWithKeyFile(byte[] buf, byte[] secret) {
      var h = ReadHeader(buf);
      if (h.Kind != "keyfile") throw Wrong();
      if (h.Iterations != KeyFileFingerprint(secret)) throw WrongKeyFile();
      var key = KeyFileKey(secret, h.Salt);
      return new Opened { Plain = Open(buf, key), Key = key };
    }
  }
}
