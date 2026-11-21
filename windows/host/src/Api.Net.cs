using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace SatoEdit {
  /// ネット: AI・拡張機能・ローカル LLM への HTTP (送り方・読み方は画面側 host.js が決め、ここは運ぶだけ)
  partial class Bridge {
    static readonly HttpClient http = MakeClient();
    readonly ConcurrentDictionary<string, CancellationTokenSource> httpJobs = new ConcurrentDictionary<string, CancellationTokenSource>();
    const string KeyMark = "\u0000SATOEDIT-API-KEY\u0000";

    static HttpClient MakeClient() {
      ServicePointManager.SecurityProtocol = SecurityProtocolType.SystemDefault;
      var h = new HttpClientHandler { AllowAutoRedirect = true, MaxAutomaticRedirections = 5, AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate };
      var c = new HttpClient(h) { Timeout = Timeout.InfiniteTimeSpan };
      c.DefaultRequestHeaders.UserAgent.ParseAdd("satoruEditor/" + Program.Version);
      return c;
    }

    /// o: { url, method, headers, body, secret, timeout }。secret があれば、ヘッダーと URL の印をその秘密 (API キー) に置き換える
    static HttpRequestMessage MakeRequest(JObj o) {
      var secret = o.Str("secret") != "" ? (Store.GetSecret(o.Str("secret")) ?? "") : "";
      string Fill(string s) => s.Replace(KeyMark, secret);
      var url = Fill(o.Str("url"));
      if (!url.StartsWith("http://", StringComparison.OrdinalIgnoreCase) && !url.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) throw new UserError("bad URL");
      var req = new HttpRequestMessage(new HttpMethod(o.Str("method", "GET").ToUpperInvariant()), url);
      string contentType = null;
      var headers = o.Obj("headers") ?? new JObj();
      foreach (var kv in headers) {
        var v = Fill(Convert.ToString(kv.Value is double d ? Json.Number(d) : kv.Value) ?? "");
        if (kv.Key.Equals("content-type", StringComparison.OrdinalIgnoreCase)) { contentType = v; continue; }
        if (kv.Key.Equals("content-length", StringComparison.OrdinalIgnoreCase)) continue;
        req.Headers.TryAddWithoutValidation(kv.Key, v);
      }
      if (o["body"] is string body) {
        req.Content = new StringContent(body, Encoding.UTF8);
        req.Content.Headers.Remove("Content-Type");
        req.Content.Headers.TryAddWithoutValidation("Content-Type", contentType ?? "text/plain;charset=UTF-8");
      }
      return req;
    }

    static string Explain(Exception e) {
      while (e is AggregateException ag && ag.InnerException != null) e = ag.InnerException;
      if (e is HttpRequestException && e.InnerException != null) {
        var inner = e.InnerException;
        while (inner.InnerException != null) inner = inner.InnerException;
        return inner.Message;
      }
      if (e is TaskCanceledException) return "timeout";
      return e.Message;
    }

    /// 全部受け取ってから返す → { status, headers, body }
    static async Task<JObj> HttpOnce(JObj o, long maxBytes = 20L * 1024 * 1024, bool raw = false) {
      using (var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(o.Num("timeout", 30000))))
      using (var req = MakeRequest(o)) {
        HttpResponseMessage res;
        try { res = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token).ConfigureAwait(false); }
        catch (Exception e) { throw new UserError(Explain(e)); }
        using (res) {
          var ms = new MemoryStream();
          using (var s = await res.Content.ReadAsStreamAsync().ConfigureAwait(false)) {
            var buf = new byte[65536];
            int n;
            while ((n = await s.ReadAsync(buf, 0, buf.Length, cts.Token).ConfigureAwait(false)) > 0) {
              ms.Write(buf, 0, n);
              if (ms.Length > maxBytes) throw new UserError("too large");
            }
          }
          var h = new JObj();
          foreach (var x in res.Headers.Concat(res.Content.Headers)) h[x.Key.ToLowerInvariant()] = string.Join(", ", x.Value);
          var r = new JObj { { "status", (double)(int)res.StatusCode }, { "headers", h } };
          if (raw) r["bodyBytes"] = ms.ToArray(); else r["body"] = Encoding.UTF8.GetString(ms.ToArray());
          return r;
        }
      }
    }

    void RegisterNet() {
      On("aiStatus", a => {
        var outo = new JObj();
        foreach (var id in (Arg(a, 0) as List<object> ?? new List<object>()).OfType<string>()) outo[id] = new JObj { { "hasKey", !string.IsNullOrEmpty(Store.GetSecret("ai." + id)) } };
        return outo;
      });
      OnBg("aiSetKey", a => {
        try { Store.SetSecret("ai." + S(a, 0), S(a, 1).Trim()); return new JObj { { "status", "ok" } }; } catch (Exception e) { return Fail(e); }
      });
      OnAsync("http", a => HttpOnce(O(a, 0)).ContinueWith(t => (object)t.Result));

      // 少しずつ届く返事: 届いた分を __stream で、終わりを __streamEnd で知らせる
      On("httpStream", a => {
        var id = S(a, 0);
        var o = O(a, 1);
        var cts = new CancellationTokenSource();
        httpJobs[id] = cts;
        Task.Run(async () => {
          var end = new JObj();
          try {
            using (var req = MakeRequest(o))
            using (var res = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token)) {
              end["status"] = (double)(int)res.StatusCode;
              using (var s = await res.Content.ReadAsStreamAsync()) {
                if ((int)res.StatusCode >= 400) {
                  var sr = new StreamReader(s, Encoding.UTF8);
                  end["body"] = await sr.ReadToEndAsync();
                } else {
                  var dec = Encoding.UTF8.GetDecoder();
                  var buf = new byte[16384];
                  var chars = new char[16384 + 4];
                  int n;
                  using (cts.Token.Register(() => { try { s.Dispose(); } catch { } })) {
                    while ((n = await s.ReadAsync(buf, 0, buf.Length, cts.Token)) > 0) {
                      int c = dec.GetChars(buf, 0, n, chars, 0);
                      if (c > 0) Send("__stream", id, new string(chars, 0, c));
                    }
                  }
                }
              }
            }
          } catch (Exception e) {
            if (cts.IsCancellationRequested) end["cancelled"] = true;
            else end["error"] = Explain(e);
          } finally {
            httpJobs.TryRemove(id, out _);
          }
          if (cts.IsCancellationRequested) end["cancelled"] = true;
          Send("__streamEnd", id, end);
        });
        return true;
      });
      On("httpCancel", a => { if (httpJobs.TryGetValue(S(a, 0), out var c)) c.Cancel(); return true; });
      RegisterServers();
    }
  }
}
