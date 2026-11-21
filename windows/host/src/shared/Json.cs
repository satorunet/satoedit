using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace SatoEdit {
  /// JSON の小さな読み書き (.NET Framework には入っていないので自前)。
  /// 値は null / bool / double / string / List<object> / JObj (順番を保つ) で表す。
  /// 書き出しは JavaScript の JSON.stringify(v, null, 2) と同じ形 (設定ファイルを Electron 版と同じ見た目に保つ)
  public class JObj : IEnumerable<KeyValuePair<string, object>> {
    readonly List<string> order = new List<string>();
    readonly Dictionary<string, object> map = new Dictionary<string, object>();

    public object this[string key] {
      get { return map.TryGetValue(key, out var v) ? v : null; }
      set {
        if (!map.ContainsKey(key)) order.Add(key);
        map[key] = value;
      }
    }
    public bool Has(string key) => map.ContainsKey(key);
    public void Remove(string key) { if (map.Remove(key)) order.Remove(key); }
    public IEnumerable<string> Keys => order;
    public int Count => order.Count;
    public IEnumerator<KeyValuePair<string, object>> GetEnumerator() {
      foreach (var k in order) yield return new KeyValuePair<string, object>(k, map[k]);
    }
    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
    public void Add(string key, object value) { this[key] = value; }

    public string Str(string key, string fallback = "") => this[key] is string s ? s : fallback;
    public double Num(string key, double fallback = 0) => this[key] is double d ? d : fallback;
    public bool Bool(string key) => this[key] is bool b && b;
    public JObj Obj(string key) => this[key] as JObj;
    public List<object> Arr(string key) => this[key] as List<object>;

    public JObj Clone() {
      var o = new JObj();
      foreach (var kv in this) o[kv.Key] = Json.Clone(kv.Value);
      return o;
    }
  }

  public static class Json {
    public static object Parse(string text) {
      var p = new Parser(text);
      p.Ws();
      var v = p.Value();
      p.Ws();
      if (p.i != text.Length) throw new FormatException("JSON: 余分な文字があります");
      return v;
    }

    /// 読めなければ fallback
    public static object TryParse(string text, object fallback = null) {
      try { return Parse(text); } catch { return fallback; }
    }

    public static object Clone(object v) {
      if (v is JObj o) return o.Clone();
      if (v is List<object> l) { var c = new List<object>(); foreach (var x in l) c.Add(Clone(x)); return c; }
      return v;
    }

    /// 1 行で書く (JSON.stringify(v))
    public static string Stringify(object v) {
      var sb = new StringBuilder();
      Write(sb, v, null, "");
      return sb.ToString();
    }

    /// 字下げして書く (JSON.stringify(v, null, 2))
    public static string Pretty(object v) {
      var sb = new StringBuilder();
      Write(sb, v, "  ", "");
      return sb.ToString();
    }

    static void Write(StringBuilder sb, object v, string indent, string cur) {
      switch (v) {
        case null: sb.Append("null"); return;
        case bool b: sb.Append(b ? "true" : "false"); return;
        case string s: Quote(sb, s); return;
        case double d: sb.Append(Number(d)); return;
        case float f: sb.Append(Number(f)); return;
        case int n: sb.Append(n.ToString(CultureInfo.InvariantCulture)); return;
        case long n: sb.Append(n.ToString(CultureInfo.InvariantCulture)); return;
        case uint n: sb.Append(n.ToString(CultureInfo.InvariantCulture)); return;
        case JObj o: {
          if (o.Count == 0) { sb.Append("{}"); return; }
          sb.Append('{');
          var next = cur + indent;
          bool first = true;
          foreach (var kv in o) {
            if (kv.Value is Undefined) continue;
            if (!first) sb.Append(',');
            first = false;
            if (indent != null) sb.Append('\n').Append(next);
            Quote(sb, kv.Key);
            sb.Append(indent != null ? ": " : ":");
            Write(sb, kv.Value, indent, next);
          }
          if (first) { sb.Length -= 1; sb.Append("{}"); return; }
          if (indent != null) sb.Append('\n').Append(cur);
          sb.Append('}');
          return;
        }
        case IDictionary<string, object> dict: {
          var o = new JObj();
          foreach (var kv in dict) o[kv.Key] = kv.Value;
          Write(sb, o, indent, cur);
          return;
        }
        case byte[] bytes: Quote(sb, Convert.ToBase64String(bytes)); return;
        case IEnumerable list: {
          var items = new List<object>();
          foreach (var x in list) items.Add(x);
          if (items.Count == 0) { sb.Append("[]"); return; }
          sb.Append('[');
          var next = cur + indent;
          for (int k = 0; k < items.Count; k++) {
            if (k > 0) sb.Append(',');
            if (indent != null) sb.Append('\n').Append(next);
            Write(sb, items[k] is Undefined ? null : items[k], indent, next);
          }
          if (indent != null) sb.Append('\n').Append(cur);
          sb.Append(']');
          return;
        }
        default: Quote(sb, v.ToString()); return;
      }
    }

    /// JavaScript と同じ数の書き方 (整数は小数点なし。NaN・無限は null)
    public static string Number(double d) {
      if (double.IsNaN(d) || double.IsInfinity(d)) return "null";
      if (d == Math.Floor(d) && Math.Abs(d) < 1e21) return d.ToString("0", CultureInfo.InvariantCulture);
      var r = d.ToString("R", CultureInfo.InvariantCulture);
      // .NET は 1E-07 のように書くので、JavaScript の 1e-7 にそろえる
      int e = r.IndexOf('E');
      if (e >= 0) {
        var mant = r.Substring(0, e);
        var exp = int.Parse(r.Substring(e + 1), CultureInfo.InvariantCulture);
        r = mant + "e" + (exp >= 0 ? "+" : "-") + Math.Abs(exp).ToString(CultureInfo.InvariantCulture);
      }
      return r;
    }

    public static void Quote(StringBuilder sb, string s) {
      sb.Append('"');
      foreach (var c in s) {
        switch (c) {
          case '"': sb.Append("\\\""); break;
          case '\\': sb.Append("\\\\"); break;
          case '\n': sb.Append("\\n"); break;
          case '\r': sb.Append("\\r"); break;
          case '\t': sb.Append("\\t"); break;
          case '\b': sb.Append("\\b"); break;
          case '\f': sb.Append("\\f"); break;
          default:
            if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
            else sb.Append(c);
            break;
        }
      }
      sb.Append('"');
    }

    public static string Quote(string s) { var sb = new StringBuilder(); Quote(sb, s); return sb.ToString(); }

    /// 書き出しで飛ばす値 (JavaScript の undefined)
    public sealed class Undefined { public static readonly Undefined Value = new Undefined(); }

    class Parser {
      readonly string s;
      public int i;
      public Parser(string text) { s = text; }

      public void Ws() { while (i < s.Length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r' || s[i] == '﻿')) i++; }

      Exception Bad() => new FormatException("JSON: " + i + " 文字目が読めません");

      public object Value() {
        if (i >= s.Length) throw Bad();
        char c = s[i];
        if (c == '{') return Obj();
        if (c == '[') return Arr();
        if (c == '"') return Str();
        if (c == 't' && Lit("true")) return true;
        if (c == 'f' && Lit("false")) return false;
        if (c == 'n' && Lit("null")) return null;
        if (c == '-' || (c >= '0' && c <= '9')) return Num();
        throw Bad();
      }

      bool Lit(string w) {
        if (string.CompareOrdinal(s, i, w, 0, w.Length) != 0) return false;
        i += w.Length;
        return true;
      }

      JObj Obj() {
        var o = new JObj();
        i++;
        Ws();
        if (i < s.Length && s[i] == '}') { i++; return o; }
        while (true) {
          Ws();
          if (i >= s.Length || s[i] != '"') throw Bad();
          var k = Str();
          Ws();
          if (i >= s.Length || s[i] != ':') throw Bad();
          i++;
          Ws();
          o[k] = Value();
          Ws();
          if (i < s.Length && s[i] == ',') { i++; continue; }
          if (i < s.Length && s[i] == '}') { i++; return o; }
          throw Bad();
        }
      }

      List<object> Arr() {
        var l = new List<object>();
        i++;
        Ws();
        if (i < s.Length && s[i] == ']') { i++; return l; }
        while (true) {
          Ws();
          l.Add(Value());
          Ws();
          if (i < s.Length && s[i] == ',') { i++; continue; }
          if (i < s.Length && s[i] == ']') { i++; return l; }
          throw Bad();
        }
      }

      string Str() {
        i++;
        var sb = new StringBuilder();
        while (true) {
          if (i >= s.Length) throw Bad();
          char c = s[i++];
          if (c == '"') return sb.ToString();
          if (c != '\\') { sb.Append(c); continue; }
          if (i >= s.Length) throw Bad();
          char e = s[i++];
          switch (e) {
            case '"': sb.Append('"'); break;
            case '\\': sb.Append('\\'); break;
            case '/': sb.Append('/'); break;
            case 'b': sb.Append('\b'); break;
            case 'f': sb.Append('\f'); break;
            case 'n': sb.Append('\n'); break;
            case 'r': sb.Append('\r'); break;
            case 't': sb.Append('\t'); break;
            case 'u':
              if (i + 4 > s.Length) throw Bad();
              sb.Append((char)Convert.ToInt32(s.Substring(i, 4), 16));
              i += 4;
              break;
            default: throw Bad();
          }
        }
      }

      double Num() {
        int start = i;
        if (s[i] == '-') i++;
        while (i < s.Length && ((s[i] >= '0' && s[i] <= '9') || s[i] == '.' || s[i] == 'e' || s[i] == 'E' || s[i] == '+' || s[i] == '-')) i++;
        if (!double.TryParse(s.Substring(start, i - start), NumberStyles.Float, CultureInfo.InvariantCulture, out var d)) throw Bad();
        return d;
      }
    }
  }
}
