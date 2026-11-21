using System;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace SatoEdit {
  /// 暗号の部品: PBKDF2・HKDF・AES-256-GCM。
  /// .NET Framework 4.8 には AES-GCM が無く、PBKDF2 も遅いので、Windows の BCrypt を直接呼ぶ。
  /// テスト (Mac の .NET 8) では .NET の標準の部品を使う
  public static class Primitives {
    public static byte[] Random(int n) {
      var b = new byte[n];
      using (var r = RandomNumberGenerator.Create()) r.GetBytes(b);
      return b;
    }

    public static byte[] Sha256(byte[] data) { using (var h = SHA256.Create()) return h.ComputeHash(data); }

    public static byte[] HmacSha256(byte[] key, byte[] data) { using (var h = new HMACSHA256(key)) return h.ComputeHash(data); }

    /// RFC 5869 (長さ 32 バイトまで)
    public static byte[] Hkdf(byte[] ikm, byte[] salt, byte[] info, int length = 32) {
      var prk = HmacSha256(salt == null || salt.Length == 0 ? new byte[32] : salt, ikm);
      var okm = new byte[length];
      var t = new byte[0];
      int pos = 0;
      for (byte n = 1; pos < length; n++) {
        var input = new byte[t.Length + info.Length + 1];
        Buffer.BlockCopy(t, 0, input, 0, t.Length);
        Buffer.BlockCopy(info, 0, input, t.Length, info.Length);
        input[input.Length - 1] = n;
        t = HmacSha256(prk, input);
        int take = Math.Min(t.Length, length - pos);
        Buffer.BlockCopy(t, 0, okm, pos, take);
        pos += take;
      }
      return okm;
    }

    public static bool Equal(byte[] a, byte[] b) {
      if (a == null || b == null || a.Length != b.Length) return false;
      int d = 0;
      for (int i = 0; i < a.Length; i++) d |= a[i] ^ b[i];
      return d == 0;
    }

#if NET48
    // ---------- Windows の BCrypt ----------
    [DllImport("bcrypt.dll", CharSet = CharSet.Unicode)] static extern int BCryptOpenAlgorithmProvider(out IntPtr phAlgorithm, string pszAlgId, string pszImplementation, int dwFlags);
    [DllImport("bcrypt.dll")] static extern int BCryptCloseAlgorithmProvider(IntPtr hAlgorithm, int dwFlags);
    [DllImport("bcrypt.dll", CharSet = CharSet.Unicode)] static extern int BCryptSetProperty(IntPtr hObject, string pszProperty, byte[] pbInput, int cbInput, int dwFlags);
    [DllImport("bcrypt.dll")] static extern int BCryptGenerateSymmetricKey(IntPtr hAlgorithm, out IntPtr phKey, IntPtr pbKeyObject, int cbKeyObject, byte[] pbSecret, int cbSecret, int dwFlags);
    [DllImport("bcrypt.dll")] static extern int BCryptDestroyKey(IntPtr hKey);
    [DllImport("bcrypt.dll")] static extern int BCryptEncrypt(IntPtr hKey, byte[] pbInput, int cbInput, ref AuthInfo pPaddingInfo, byte[] pbIV, int cbIV, byte[] pbOutput, int cbOutput, out int pcbResult, int dwFlags);
    [DllImport("bcrypt.dll")] static extern int BCryptDecrypt(IntPtr hKey, byte[] pbInput, int cbInput, ref AuthInfo pPaddingInfo, byte[] pbIV, int cbIV, byte[] pbOutput, int cbOutput, out int pcbResult, int dwFlags);
    [DllImport("bcrypt.dll")] static extern int BCryptDeriveKeyPBKDF2(IntPtr hPrf, byte[] pbPassword, int cbPassword, byte[] pbSalt, int cbSalt, ulong cIterations, byte[] pbDerivedKey, int cbDerivedKey, int dwFlags);

    [StructLayout(LayoutKind.Sequential)]
    struct AuthInfo {
      public int cbSize, dwInfoVersion;
      public IntPtr pbNonce; public int cbNonce;
      public IntPtr pbAuthData; public int cbAuthData;
      public IntPtr pbTag; public int cbTag;
      public IntPtr pbMacContext; public int cbMacContext;
      public int cbAAD; public long cbData; public int dwFlags;
    }

    const int BCRYPT_ALG_HANDLE_HMAC_FLAG = 8;

    public static byte[] Pbkdf2(byte[] password, byte[] salt, int iterations, int length = 32) {
      if (BCryptOpenAlgorithmProvider(out var alg, "SHA256", null, BCRYPT_ALG_HANDLE_HMAC_FLAG) != 0) throw new CryptographicException("BCrypt SHA256");
      try {
        var key = new byte[length];
        // 空のパスワードは BCrypt が受け付けないことがあるので、そのときだけ .NET の部品を使う
        if (password.Length == 0) return new Rfc2898DeriveBytes(password, salt, iterations, HashAlgorithmName.SHA256).GetBytes(length);
        int st = BCryptDeriveKeyPBKDF2(alg, password, password.Length, salt, salt.Length, (ulong)iterations, key, length, 0);
        if (st != 0) throw new CryptographicException("PBKDF2 " + st.ToString("x"));
        return key;
      } finally { BCryptCloseAlgorithmProvider(alg, 0); }
    }

    static IntPtr GcmKey(byte[] key, out IntPtr alg) {
      if (BCryptOpenAlgorithmProvider(out alg, "AES", null, 0) != 0) throw new CryptographicException("BCrypt AES");
      var mode = System.Text.Encoding.Unicode.GetBytes("ChainingModeGCM\0");
      if (BCryptSetProperty(alg, "ChainingMode", mode, mode.Length, 0) != 0) throw new CryptographicException("GCM");
      if (BCryptGenerateSymmetricKey(alg, out var h, IntPtr.Zero, 0, key, key.Length, 0) != 0) throw new CryptographicException("key");
      return h;
    }

    /// → 暗号文 (タグは tag に入れる)
    public static byte[] GcmEncrypt(byte[] key, byte[] nonce, byte[] plain, byte[] aad, byte[] tag) {
      var hKey = GcmKey(key, out var alg);
      var hn = GCHandle.Alloc(nonce, GCHandleType.Pinned);
      var ha = GCHandle.Alloc(aad, GCHandleType.Pinned);
      var ht = GCHandle.Alloc(tag, GCHandleType.Pinned);
      try {
        var info = new AuthInfo {
          cbSize = Marshal.SizeOf(typeof(AuthInfo)), dwInfoVersion = 1,
          pbNonce = hn.AddrOfPinnedObject(), cbNonce = nonce.Length,
          pbAuthData = ha.AddrOfPinnedObject(), cbAuthData = aad.Length,
          pbTag = ht.AddrOfPinnedObject(), cbTag = tag.Length,
        };
        var output = new byte[plain.Length];
        int st = BCryptEncrypt(hKey, plain, plain.Length, ref info, null, 0, output, output.Length, out _, 0);
        if (st != 0) throw new CryptographicException("encrypt " + st.ToString("x"));
        return output;
      } finally {
        hn.Free(); ha.Free(); ht.Free();
        BCryptDestroyKey(hKey); BCryptCloseAlgorithmProvider(alg, 0);
      }
    }

    /// タグが合わなければ例外
    public static byte[] GcmDecrypt(byte[] key, byte[] nonce, byte[] cipher, byte[] aad, byte[] tag) {
      var hKey = GcmKey(key, out var alg);
      var hn = GCHandle.Alloc(nonce, GCHandleType.Pinned);
      var ha = GCHandle.Alloc(aad, GCHandleType.Pinned);
      var ht = GCHandle.Alloc(tag, GCHandleType.Pinned);
      try {
        var info = new AuthInfo {
          cbSize = Marshal.SizeOf(typeof(AuthInfo)), dwInfoVersion = 1,
          pbNonce = hn.AddrOfPinnedObject(), cbNonce = nonce.Length,
          pbAuthData = ha.AddrOfPinnedObject(), cbAuthData = aad.Length,
          pbTag = ht.AddrOfPinnedObject(), cbTag = tag.Length,
        };
        var output = new byte[cipher.Length];
        int st = BCryptDecrypt(hKey, cipher, cipher.Length, ref info, null, 0, output, output.Length, out _, 0);
        if (st != 0) throw new CryptographicException("decrypt " + st.ToString("x"));
        return output;
      } finally {
        hn.Free(); ha.Free(); ht.Free();
        BCryptDestroyKey(hKey); BCryptCloseAlgorithmProvider(alg, 0);
      }
    }
#else
    public static byte[] Pbkdf2(byte[] password, byte[] salt, int iterations, int length = 32) =>
      Rfc2898DeriveBytes.Pbkdf2(password, salt, iterations, HashAlgorithmName.SHA256, length);

    public static byte[] GcmEncrypt(byte[] key, byte[] nonce, byte[] plain, byte[] aad, byte[] tag) {
      using (var g = new AesGcm(key, 16)) {
        var output = new byte[plain.Length];
        g.Encrypt(nonce, plain, output, tag, aad);
        return output;
      }
    }

    public static byte[] GcmDecrypt(byte[] key, byte[] nonce, byte[] cipher, byte[] aad, byte[] tag) {
      using (var g = new AesGcm(key, 16)) {
        var output = new byte[cipher.Length];
        g.Decrypt(nonce, cipher, tag, output, aad);
        return output;
      }
    }
#endif
  }
}
