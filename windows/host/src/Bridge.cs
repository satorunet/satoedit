using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Web.WebView2.Core;

namespace SatoEdit {
  /// 画面側 (renderer/src/host.js) とのやりとり。
  ///   画面 → 本体: { k: "call", id, name, args }
  ///   本体 → 画面: { k: "reply", id, ok, value | error } と { k: "event", channel, args }
  /// 呼び出しは UI のスレッドで受ける。時間のかかるものは各ハンドラの中で Task.Run に回す
  partial class Bridge {
    readonly MainForm form;
    readonly Dictionary<string, Func<List<object>, Task<object>>> handlers = new Dictionary<string, Func<List<object>, Task<object>>>();
    public CoreWebView2 Web => form.Web;

    public Bridge(MainForm form) {
      this.form = form;
      RegisterApp();
      RegisterFiles();
      RegisterCrypto();
      RegisterTools();
      RegisterPrint();
      RegisterNet();
      RegisterCollab();
      RegisterPlugins();
      RegisterLocalLLM();
      RegisterLibrary();
    }

    /// UI のスレッドですぐ答えるもの
    void On(string name, Func<List<object>, object> fn) => handlers[name] = a => Task.FromResult(fn(a));
    /// 待ち合わせのあるもの (ダイアログなど)
    void OnAsync(string name, Func<List<object>, Task<object>> fn) => handlers[name] = fn;
    /// 裏のスレッドで行うもの (ファイル・暗号・ネット)
    void OnBg(string name, Func<List<object>, object> fn) => handlers[name] = a => Task.Run(() => fn(a));

    public async void Receive(CoreWebView2WebMessageReceivedEventArgs e) {
      JObj msg;
      try { msg = Json.Parse(e.WebMessageAsJson) as JObj; } catch { return; }
      if (msg == null) return;
      var kind = msg.Str("k");
      if (kind == "drop") { Dropped(e); return; }
      if (kind != "call") return;
      var id = msg["id"];
      var name = msg.Str("name");
      var args = msg.Arr("args") ?? new List<object>();
      object value = null;
      Exception error = null;
      try {
        if (!handlers.TryGetValue(name, out var fn)) throw new InvalidOperationException("unknown call: " + name);
        value = await fn(args);
      } catch (Exception ex) {
        error = ex is AggregateException ag && ag.InnerException != null ? ag.InnerException : ex;
        if (!(error is UserError)) Log.Error("call " + name, error);
      }
      var reply = new JObj { { "k", "reply" }, { "id", id }, { "ok", error == null } };
      if (error == null) reply["value"] = value;
      else reply["error"] = ErrorObject(error);
      Post(reply);
    }

    /// 例外 → 画面に渡す形 { message, code, key, params } (key があれば画面側で訳す)
    public static JObj ErrorObject(Exception e) {
      var o = new JObj { { "message", e.Message } };
      if (e is UserError u) {
        if (u.Key != null) { o["key"] = u.Key; o["params"] = u.Params; }
        if (u.Detail != null) o["detail"] = u.Detail;
        if (u.Code != null) o["code"] = u.Code;
      }
      if (e is Codec.CodecError c) { o["key"] = c.Key; o["params"] = c.Params; }
      if (e is FileCrypto.CryptoError f) o["code"] = f.Code;
      if (e is System.IO.FileNotFoundException) o["code"] = "ENOENT";
      if (e is System.IO.DirectoryNotFoundException) o["code"] = "ENOENT";
      if (e is UnauthorizedAccessException) o["code"] = "EACCES";
      return o;
    }

    /// main.js の fail(e) と同じ形 { status: 'error', code, message }
    public static JObj Fail(Exception e) {
      var o = ErrorObject(e is AggregateException ag && ag.InnerException != null ? ag.InnerException : e);
      o["status"] = "error";
      if (!o.Has("code")) o["code"] = "";
      return o;
    }

    void Post(JObj o) {
      var text = Json.Stringify(o);
      if (form.InvokeRequired) { form.BeginInvoke((Action)(() => PostNow(text))); return; }
      PostNow(text);
    }
    void PostNow(string text) {
      try { Web?.PostWebMessageAsJson(text); } catch (Exception e) { Log.Error("post", e); }
    }

    /// 画面側へのお知らせ (どのスレッドからでも呼べる)
    public void Send(string channel, params object[] args) {
      Post(new JObj { { "k", "event" }, { "channel", channel }, { "args", args.ToList() } });
    }

    // 引数を取り出す
    static object Arg(List<object> a, int i) => i < a.Count ? a[i] : null;
    static string S(List<object> a, int i, string fallback = "") => Arg(a, i) is string s ? s : (Arg(a, i) is double d ? Json.Number(d) : fallback);
    static JObj O(List<object> a, int i) => Arg(a, i) as JObj ?? new JObj();
    static bool B(List<object> a, int i) => Arg(a, i) is bool b && b;
    static double N(List<object> a, int i, double fallback = 0) => Arg(a, i) is double d ? d : (Arg(a, i) is string s && double.TryParse(s, out var v) ? v : fallback);
  }

  /// 画面に見せるエラー。Message は日本語、Key と Params があれば画面側で今の言語に訳す
  class UserError : Exception {
    public string Key, Code, Detail; public JObj Params;
    /// 訳す部分 (prefix) と、訳さない部分 (detail。相手のサーバのメッセージなど) をつないだもの
    public static UserError With(string prefix, string detail) => new UserError(prefix + detail) { Key = prefix, Detail = detail };
    public UserError(string message, string code = null) : base(message) { Code = code; }
    public UserError(string key, JObj prms, string code = null) : base(Format(key, prms)) { Key = key; Params = prms; Code = code; }
    static string Format(string key, JObj p) {
      var s = key;
      foreach (var kv in p) s = s.Replace("{" + kv.Key + "}", Convert.ToString(kv.Value is double d ? Json.Number(d) : kv.Value));
      return s;
    }
  }
}
