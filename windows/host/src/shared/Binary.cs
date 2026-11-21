using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace SatoEdit {
  /// テキストではないデータの見分け (shared/binary.js と同じ決まり)
  public static class Binary {
    /// 先頭の一部を見て、バイナリらしいか。NUL が入っていればバイナリ (UTF-16 のテキストは除く)。制御文字が多くてもバイナリ
    public static bool LooksBinary(byte[] data) {
      int n = Math.Min(8192, data.Length);
      if (n == 0) return false;
      byte At(int i) => i < n ? data[i] : (byte)0;
      if ((At(0) == 0xFF && At(1) == 0xFE) || (At(0) == 0xFE && At(1) == 0xFF) || (At(0) == 0xEF && At(1) == 0xBB && At(2) == 0xBF)) {
        return false; // 範囲の外は 0 として比べるので、短いときは一致しない
      }
      int nul = 0, even = 0, odd = 0;
      for (int i = 0; i < n; i++) if (data[i] == 0) { nul++; if (i % 2 == 0) even++; else odd++; }
      if (nul > 0) {
        int half = n / 2;
        if (half > 0 && ((even > half * 0.4 && odd == 0) || (odd > half * 0.4 && even == 0))) return false;
        return true;
      }
      int controls = 0;
      for (int i = 0; i < n; i++) {
        var v = data[i];
        if ((v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D && v != 0x0C && v != 0x1B && v != 0x08) || v == 0x7F) controls++;
      }
      return (double)controls / n > 0.1;
    }

    static readonly Dictionary<string, string> ImageTypes = new Dictionary<string, string> {
      { "png", "image/png" }, { "jpg", "image/jpeg" }, { "jpeg", "image/jpeg" }, { "gif", "image/gif" }, { "webp", "image/webp" }, { "bmp", "image/bmp" }, { "ico", "image/x-icon" },
    };

    /// 画像として見るファイルか (SVG は文字なのでエディタで開く)
    public static string ImageType(string name) {
      var m = Regex.Match(name ?? "", @"\.([A-Za-z0-9]+)$");
      return m.Success && ImageTypes.TryGetValue(m.Groups[1].Value.ToLowerInvariant(), out var t) ? t : null;
    }
  }
}
