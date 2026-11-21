using System;

namespace SatoEdit {
  /// ChaCha20-Poly1305 (RFC 8439)。.NET Framework には無いので自前 (共同編集の通信に使う。Mac 版・Electron 版と同じもの)
  public static class ChaChaPoly {
    static uint Rotl(uint v, int c) => (v << c) | (v >> (32 - c));
    static uint Le32(byte[] b, int i) => (uint)(b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24));

    static void Block(uint[] key, uint counter, uint[] nonce, byte[] output) {
      var s = new uint[16];
      s[0] = 0x61707865; s[1] = 0x3320646e; s[2] = 0x79622d32; s[3] = 0x6b206574;
      Array.Copy(key, 0, s, 4, 8);
      s[12] = counter; s[13] = nonce[0]; s[14] = nonce[1]; s[15] = nonce[2];
      var x = (uint[])s.Clone();
      void Q(int a, int b, int c, int d) {
        x[a] += x[b]; x[d] = Rotl(x[d] ^ x[a], 16);
        x[c] += x[d]; x[b] = Rotl(x[b] ^ x[c], 12);
        x[a] += x[b]; x[d] = Rotl(x[d] ^ x[a], 8);
        x[c] += x[d]; x[b] = Rotl(x[b] ^ x[c], 7);
      }
      for (int i = 0; i < 10; i++) {
        Q(0, 4, 8, 12); Q(1, 5, 9, 13); Q(2, 6, 10, 14); Q(3, 7, 11, 15);
        Q(0, 5, 10, 15); Q(1, 6, 11, 12); Q(2, 7, 8, 13); Q(3, 4, 9, 14);
      }
      for (int i = 0; i < 16; i++) {
        uint v = x[i] + s[i];
        output[i * 4] = (byte)v; output[i * 4 + 1] = (byte)(v >> 8); output[i * 4 + 2] = (byte)(v >> 16); output[i * 4 + 3] = (byte)(v >> 24);
      }
    }

    static uint[] Words(byte[] b, int n) { var w = new uint[n]; for (int i = 0; i < n; i++) w[i] = Le32(b, i * 4); return w; }

    static void Xor(byte[] key, byte[] nonce, uint counter, byte[] input, byte[] output) {
      var k = Words(key, 8);
      var n = Words(nonce, 3);
      var block = new byte[64];
      for (int pos = 0; pos < input.Length; pos += 64) {
        Block(k, counter++, n, block);
        int len = Math.Min(64, input.Length - pos);
        for (int i = 0; i < len; i++) output[pos + i] = (byte)(input[pos + i] ^ block[i]);
      }
    }

    // Poly1305 (26 ビットずつの 5 つに分けて計算する、よくあるやり方)
    static byte[] Poly1305(byte[] key, byte[] msg) {
      uint r0 = Le32(key, 0) & 0x3ffffff, r1 = (Le32(key, 3) >> 2) & 0x3ffff03, r2 = (Le32(key, 6) >> 4) & 0x3ffc0ff, r3 = (Le32(key, 9) >> 6) & 0x3f03fff, r4 = (Le32(key, 12) >> 8) & 0x00fffff;
      uint s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5;
      uint h0 = 0, h1 = 0, h2 = 0, h3 = 0, h4 = 0;
      var blk = new byte[17];
      for (int pos = 0; pos < msg.Length; pos += 16) {
        int len = Math.Min(16, msg.Length - pos);
        Array.Clear(blk, 0, 17);
        Buffer.BlockCopy(msg, pos, blk, 0, len);
        // 16 バイトに満たない最後のかたまりは、すぐ後ろに 1 を置き、2^128 の印は付けない
        if (len < 16) blk[len] = 1;
        uint hibit = len == 16 ? (1u << 24) : 0;
        h0 += Le32(blk, 0) & 0x3ffffff;
        h1 += (Le32(blk, 3) >> 2) & 0x3ffffff;
        h2 += (Le32(blk, 6) >> 4) & 0x3ffffff;
        h3 += (Le32(blk, 9) >> 6) & 0x3ffffff;
        h4 += (Le32(blk, 12) >> 8) | hibit;
        ulong d0 = (ulong)h0 * r0 + (ulong)h1 * s4 + (ulong)h2 * s3 + (ulong)h3 * s2 + (ulong)h4 * s1;
        ulong d1 = (ulong)h0 * r1 + (ulong)h1 * r0 + (ulong)h2 * s4 + (ulong)h3 * s3 + (ulong)h4 * s2;
        ulong d2 = (ulong)h0 * r2 + (ulong)h1 * r1 + (ulong)h2 * r0 + (ulong)h3 * s4 + (ulong)h4 * s3;
        ulong d3 = (ulong)h0 * r3 + (ulong)h1 * r2 + (ulong)h2 * r1 + (ulong)h3 * r0 + (ulong)h4 * s4;
        ulong d4 = (ulong)h0 * r4 + (ulong)h1 * r3 + (ulong)h2 * r2 + (ulong)h3 * r1 + (ulong)h4 * r0;
        uint c = (uint)(d0 >> 26); h0 = (uint)d0 & 0x3ffffff;
        d1 += c; c = (uint)(d1 >> 26); h1 = (uint)d1 & 0x3ffffff;
        d2 += c; c = (uint)(d2 >> 26); h2 = (uint)d2 & 0x3ffffff;
        d3 += c; c = (uint)(d3 >> 26); h3 = (uint)d3 & 0x3ffffff;
        d4 += c; c = (uint)(d4 >> 26); h4 = (uint)d4 & 0x3ffffff;
        h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffff;
        h1 += c;
      }
      uint cc = h1 >> 26; h1 &= 0x3ffffff;
      h2 += cc; cc = h2 >> 26; h2 &= 0x3ffffff;
      h3 += cc; cc = h3 >> 26; h3 &= 0x3ffffff;
      h4 += cc; cc = h4 >> 26; h4 &= 0x3ffffff;
      h0 += cc * 5; cc = h0 >> 26; h0 &= 0x3ffffff;
      h1 += cc;
      uint g0 = h0 + 5; cc = g0 >> 26; g0 &= 0x3ffffff;
      uint g1 = h1 + cc; cc = g1 >> 26; g1 &= 0x3ffffff;
      uint g2 = h2 + cc; cc = g2 >> 26; g2 &= 0x3ffffff;
      uint g3 = h3 + cc; cc = g3 >> 26; g3 &= 0x3ffffff;
      uint g4 = h4 + cc - (1u << 26);
      uint mask = (g4 >> 31) - 1;
      g0 &= mask; g1 &= mask; g2 &= mask; g3 &= mask; g4 &= mask;
      mask = ~mask;
      h0 = (h0 & mask) | g0; h1 = (h1 & mask) | g1; h2 = (h2 & mask) | g2; h3 = (h3 & mask) | g3; h4 = (h4 & mask) | g4;
      h0 = (h0 | (h1 << 26)) & 0xffffffff;
      h1 = ((h1 >> 6) | (h2 << 20)) & 0xffffffff;
      h2 = ((h2 >> 12) | (h3 << 14)) & 0xffffffff;
      h3 = ((h3 >> 18) | (h4 << 8)) & 0xffffffff;
      ulong f = (ulong)h0 + Le32(key, 16); h0 = (uint)f;
      f = (ulong)h1 + Le32(key, 20) + (f >> 32); h1 = (uint)f;
      f = (ulong)h2 + Le32(key, 24) + (f >> 32); h2 = (uint)f;
      f = (ulong)h3 + Le32(key, 28) + (f >> 32); h3 = (uint)f;
      var tag = new byte[16];
      void Put(int i, uint v) { tag[i] = (byte)v; tag[i + 1] = (byte)(v >> 8); tag[i + 2] = (byte)(v >> 16); tag[i + 3] = (byte)(v >> 24); }
      Put(0, h0); Put(4, h1); Put(8, h2); Put(12, h3);
      return tag;
    }

    static byte[] MacData(byte[] aad, byte[] cipher) {
      int pa = (16 - aad.Length % 16) % 16, pc = (16 - cipher.Length % 16) % 16;
      var m = new byte[aad.Length + pa + cipher.Length + pc + 16];
      Buffer.BlockCopy(aad, 0, m, 0, aad.Length);
      Buffer.BlockCopy(cipher, 0, m, aad.Length + pa, cipher.Length);
      long al = aad.Length, cl = cipher.Length;
      int o = m.Length - 16;
      for (int i = 0; i < 8; i++) { m[o + i] = (byte)(al >> (8 * i)); m[o + 8 + i] = (byte)(cl >> (8 * i)); }
      return m;
    }

    static byte[] PolyKey(byte[] key, byte[] nonce) {
      var block = new byte[64];
      Block(Words(key, 8), 0, Words(nonce, 3), block);
      var pk = new byte[32];
      Buffer.BlockCopy(block, 0, pk, 0, 32);
      return pk;
    }

    /// → 暗号文 + タグ 16
    public static byte[] Seal(byte[] key, byte[] nonce, byte[] plain, byte[] aad = null) {
      aad = aad ?? new byte[0];
      var c = new byte[plain.Length];
      Xor(key, nonce, 1, plain, c);
      var tag = Poly1305(PolyKey(key, nonce), MacData(aad, c));
      var o = new byte[c.Length + 16];
      Buffer.BlockCopy(c, 0, o, 0, c.Length);
      Buffer.BlockCopy(tag, 0, o, c.Length, 16);
      return o;
    }

    /// タグが合わなければ null
    public static byte[] Open(byte[] key, byte[] nonce, byte[] cipherAndTag, byte[] aad = null) {
      aad = aad ?? new byte[0];
      if (cipherAndTag.Length < 16) return null;
      var c = new byte[cipherAndTag.Length - 16];
      Buffer.BlockCopy(cipherAndTag, 0, c, 0, c.Length);
      var tag = new byte[16];
      Buffer.BlockCopy(cipherAndTag, c.Length, tag, 0, 16);
      if (!Primitives.Equal(tag, Poly1305(PolyKey(key, nonce), MacData(aad, c)))) return null;
      var p = new byte[c.Length];
      Xor(key, nonce, 1, c, p);
      return p;
    }
  }
}
