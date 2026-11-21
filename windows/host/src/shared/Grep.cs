using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace SatoEdit {
  /// フォルダ内検索 (core/grep.js・Mac 版 Grep.swift と同じ決まり)
  public static class Grep {
    static readonly HashSet<string> SkippedDirectories = new HashSet<string> { "node_modules", ".build", "DerivedData", "Pods", ".git" };
    const long MaxFileSize = 20L * 1024 * 1024;

    public static Regex MakeRegex(string pattern, bool useRegex, bool caseSensitive) {
      var opts = RegexOptions.Multiline | RegexOptions.CultureInvariant;
      if (!caseSensitive) opts |= RegexOptions.IgnoreCase;
      return new Regex(useRegex ? pattern : Regex.Escape(pattern ?? ""), opts);
    }

    /// "*.txt;*.md" のようなファイル名マスク → 判定する関数。空なら全ファイル
    public static Func<string, bool> MakeMaskMatcher(string fileMask) {
      var list = Regex.Split(fileMask ?? "", "[;, ]+").Where(s => s.Length > 0).ToList();
      if (list.Count == 0) return _ => true;
      var regs = list.Select(m => new Regex("^" + string.Concat(m.Select(c => c == '*' ? ".*" : c == '?' ? "." : Regex.Escape(c.ToString()))) + "$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)).ToList();
      return name => regs.Any(r => r.IsMatch(name));
    }

    public static IEnumerable<string> Files(string root, bool recursive) {
      FileSystemInfo[] entries;
      try { entries = new DirectoryInfo(root).GetFileSystemInfos(); } catch { yield break; }
      Array.Sort(entries, (a, b) => string.CompareOrdinal(a.Name, b.Name));
      foreach (var e in entries) {
        if (e.Name.StartsWith(".")) continue; // 隠しファイルは見ない
        bool isDir = (e.Attributes & FileAttributes.Directory) != 0;
        if (isDir) {
          // リンク (ジャンクション) の先はたどらない (ぐるぐる回らないように)
          if (recursive && !SkippedDirectories.Contains(e.Name) && (e.Attributes & FileAttributes.ReparsePoint) == 0) {
            foreach (var f in Files(e.FullName, recursive)) yield return f;
          }
        } else {
          yield return e.FullName;
        }
      }
    }

    /// バイナリっぽいファイルは null
    public static string ReadText(string file) {
      byte[] buf;
      try {
        if (new FileInfo(file).Length > MaxFileSize) return null;
        buf = File.ReadAllBytes(file);
      } catch { return null; }
      int n = Math.Min(8192, buf.Length);
      bool utf16 = buf.Length >= 2 && ((buf[0] == 0xFF && buf[1] == 0xFE) || (buf[0] == 0xFE && buf[1] == 0xFF));
      if (!utf16) for (int i = 0; i < n; i++) if (buf[i] == 0) return null;
      try { return Codec.Decode(buf).Text; } catch { return null; }
    }

    public class Match { public string File; public int Line; public string Text; }
    public class Result { public int Count, Scanned; public bool Truncated; }

    /// 見つけるたびに onMatch を呼ぶ。途中で止めるには isCancelled が true を返す
    public static Result Search(string root, string pattern, bool useRegex, bool caseSensitive, string fileMask, bool recursive, int maxResults, Action<Match> onMatch, Func<bool> isCancelled) {
      var regex = MakeRegex(pattern, useRegex, caseSensitive);
      var matches = MakeMaskMatcher(fileMask);
      int max = maxResults > 0 ? maxResults : 10000;
      int count = 0, scanned = 0;
      foreach (var file in Files(root, recursive)) {
        if (isCancelled() || count >= max) break;
        if (!matches(Path.GetFileName(file))) continue;
        var text = ReadText(file);
        scanned += 1;
        if (text == null) continue;
        var lines = text.Split('\n');
        for (int k = 0; k < lines.Length; k++) {
          if (regex.IsMatch(lines[k])) {
            onMatch(new Match { File = file, Line = k + 1, Text = lines[k].Length > 500 ? lines[k].Substring(0, 500) : lines[k] });
            count += 1;
            if (count >= max) break;
          }
        }
      }
      return new Result { Count = count, Scanned = scanned, Truncated = count >= max };
    }
  }
}
