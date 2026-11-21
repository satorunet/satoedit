using System;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace SatoEdit {
  /// スマホの認証アプリ (Google Authenticator など) と同じ 6 桁コード (RFC 6238, HMAC-SHA1, 30 秒ごと)。core/totp.js と同じ
  public static class Totp {
    public const int Period = 30;
    public const int Digits = 6;

    public static byte[] NewSecret() => Primitives.Random(20);

    public static string CodeAt(byte[] secret, long counter) {
      var msg = new byte[8];
      for (int i = 7; i >= 0; i--) { msg[i] = (byte)(counter & 0xFF); counter >>= 8; }
      byte[] mac;
      using (var h = new HMACSHA1(secret)) mac = h.ComputeHash(msg);
      int offset = mac[mac.Length - 1] & 0x0F;
      int value = ((mac[offset] & 0x7F) << 24) | (mac[offset + 1] << 16) | (mac[offset + 2] << 8) | mac[offset + 3];
      return (value % 1000000).ToString("D6");
    }

    public static double Now() => (DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;

    public static string Code(byte[] secret, double timeSeconds) => CodeAt(secret, (long)Math.Floor(Math.Max(0, timeSeconds) / Period));

    /// 入力されたコードが合っているか。時計のずれに備えて前後 1 つ (±30 秒) まで認める
    public static bool Verify(string input, byte[] secret, double? timeSeconds = null, int window = 1) {
      var entered = Regex.Replace(input ?? "", @"\s", "");
      if (!Regex.IsMatch(entered, "^[0-9]{6}$")) return false;
      long counter = (long)Math.Floor(Math.Max(0, timeSeconds ?? Now()) / Period);
      bool ok = false;
      for (int d = -window; d <= window; d++) {
        if (counter + d < 0) continue;
        if (CodeAt(secret, counter + d) == entered) ok = true; // 途中で抜けず、毎回すべて比べる
      }
      return ok;
    }

    /// 認証アプリに手で打ち込むための表記 (Base32、= の詰め物なし)
    public static string Base32(byte[] buf) {
      const string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
      var sb = new StringBuilder();
      int buffer = 0, bits = 0;
      foreach (var b in buf) {
        buffer = (buffer << 8) | b;
        bits += 8;
        while (bits >= 5) {
          sb.Append(alphabet[(buffer >> (bits - 5)) & 0x1F]);
          bits -= 5;
        }
        buffer &= (1 << bits) - 1;
      }
      if (bits > 0) sb.Append(alphabet[(buffer << (5 - bits)) & 0x1F]);
      return sb.ToString();
    }

    /// encodeURIComponent と同じ (さらに !'()* も % にする)
    public static string Enc(string s) {
      var sb = new StringBuilder();
      foreach (var b in Encoding.UTF8.GetBytes(s)) {
        char c = (char)b;
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') sb.Append(c);
        else sb.Append('%').Append(b.ToString("X2"));
      }
      return sb.ToString();
    }

    /// QR コードにする登録用の URL
    public static string Uri(byte[] secret, string account, string issuer) =>
      $"otpauth://totp/{Enc(issuer)}:{Enc(account)}?secret={Base32(secret)}&issuer={Enc(issuer)}&algorithm=SHA1&digits={Digits}&period={Period}";
  }
}
