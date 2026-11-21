using System;
using System.Linq;
using System.Text;

namespace SatoEdit {
  /// 共同編集の通信の暗号化 (core/collabcipher.js・Mac 版 CollabCipher.swift と同じ決まり。Mac と Windows で一緒に編集できる)。
  /// 共有コードから鍵を作り、1 通ずつ ChaCha20-Poly1305 で暗号化する。向きごとに別の鍵、通し番号で順番の入れ替え・再送を断る
  public class CollabCipher {
    public const string Alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // 紛らわしい 0 O 1 I は使わない

    /// 新しい共有コード (16 文字、4 文字ずつ区切る)
    public static string NewCode() {
      var bytes = Primitives.Random(16);
      var chars = bytes.Select(b => Alphabet[b % Alphabet.Length]).ToArray();
      return string.Join("-", new[] { 0, 4, 8, 12 }.Select(i => new string(chars, i, 4)));
    }

    /// 入力されたコードの表記ゆれ (小文字・空白・ハイフン) をそろえる
    public static string Normalize(string code) => new string((code ?? "").ToUpperInvariant().Where(c => Alphabet.IndexOf(c) >= 0).ToArray());

    readonly byte[] sendKey, receiveKey;
    ulong sendCounter, receiveCounter;
    readonly object gate = new object();

    public CollabCipher(string code, bool isHost) {
      var ikm = Encoding.UTF8.GetBytes(Normalize(code));
      var salt = Encoding.UTF8.GetBytes("satoru-editor collab v1");
      byte[] Key(string label) => Primitives.Hkdf(ikm, salt, Encoding.UTF8.GetBytes(label));
      var h2g = Key("host->guest");
      var g2h = Key("guest->host");
      sendKey = isHost ? h2g : g2h;
      receiveKey = isHost ? g2h : h2g;
    }

    /// 平文 1 通 → 送る 1 行 (base64、改行なし)
    public string Seal(byte[] plain) {
      lock (gate) {
        var payload = new byte[8 + plain.Length];
        for (int i = 0; i < 8; i++) payload[i] = (byte)(sendCounter >> (56 - 8 * i));
        Buffer.BlockCopy(plain, 0, payload, 8, plain.Length);
        sendCounter++;
        var nonce = Primitives.Random(12);
        var body = ChaChaPoly.Seal(sendKey, nonce, payload);
        var o = new byte[12 + body.Length];
        Buffer.BlockCopy(nonce, 0, o, 0, 12);
        Buffer.BlockCopy(body, 0, o, 12, body.Length);
        return Convert.ToBase64String(o);
      }
    }

    /// 受け取った 1 行 → 平文。鍵違い・改ざん・順番違いなら null
    public byte[] Open(string line) {
      try {
        var raw = Convert.FromBase64String((line ?? "").Trim());
        if (raw.Length < 12 + 16 + 8) return null;
        var nonce = new byte[12];
        Buffer.BlockCopy(raw, 0, nonce, 0, 12);
        var rest = new byte[raw.Length - 12];
        Buffer.BlockCopy(raw, 12, rest, 0, rest.Length);
        var payload = ChaChaPoly.Open(receiveKey, nonce, rest);
        if (payload == null) return null;
        ulong n = 0;
        for (int i = 0; i < 8; i++) n = (n << 8) | payload[i];
        lock (gate) {
          if (n != receiveCounter) return null;
          receiveCounter++;
        }
        var plain = new byte[payload.Length - 8];
        Buffer.BlockCopy(payload, 8, plain, 0, plain.Length);
        return plain;
      } catch {
        return null;
      }
    }
  }
}
