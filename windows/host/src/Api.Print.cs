using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace SatoEdit {
  /// 印刷・PDF・Word (.docx)・スクリーンショット
  partial class Bridge {
    /// HTML を見えない WebView で開いて fn を行う。WebView はウインドウの中の、表の画面の後ろに置く (別のウインドウだと描画されないことがある)
    async Task<T> WithPage<T>(string html, int cssWidth, Func<CoreWebView2, Task<T>> fn, bool fixWidth = false) {
      var tmp = Path.Combine(Path.GetTempPath(), $"satoruEditor-print-{System.Diagnostics.Process.GetCurrentProcess().Id}-{DateTime.Now.Ticks}.html");
      File.WriteAllText(tmp, html, new UTF8Encoding(false));
      var k = form.DeviceDpi / 96.0;
      var view = new WebView2 { Location = new Point(0, 0), Size = new Size((int)Math.Round(Math.Max(200, Math.Min(4000, cssWidth)) * k), (int)Math.Round(600 * k)), Visible = true };
      form.Controls.Add(view);
      view.SendToBack();
      try {
        await view.EnsureCoreWebView2Async(form.Env);
        var w = view.CoreWebView2;
        w.Settings.IsScriptEnabled = false;
        w.Settings.AreDefaultContextMenusEnabled = false;
        if (fixWidth) {
          // 横幅は CSS のピクセルで決める (画面の拡大率に左右されないように)
          await w.CallDevToolsProtocolMethodAsync("Emulation.setDeviceMetricsOverride", Json.Stringify(new JObj {
            { "width", (double)Math.Max(200, Math.Min(4000, cssWidth)) }, { "height", 600.0 }, { "deviceScaleFactor", form.DeviceDpi / 96.0 }, { "mobile", false },
          }));
        }
        var done = new TaskCompletionSource<bool>();
        w.NavigationCompleted += (s, e) => done.TrySetResult(e.IsSuccess);
        w.Navigate(new Uri(tmp).AbsoluteUri);
        if (await Task.WhenAny(done.Task, Task.Delay(20000)) != done.Task) throw new UserError("時間切れ");
        return await fn(w);
      } finally {
        form.Controls.Remove(view);
        view.Dispose();
        try { File.Delete(tmp); } catch { } // 残っても害はない
      }
    }

    static JObj Margins(JObj m) => m ?? new JObj { { "top", 0.0 }, { "bottom", 0.0 }, { "left", 0.0 }, { "right", 0.0 } };

    /// margins はインチ。省くと余白なし (原稿用紙は用紙いっぱいに枠を描く)
    Task<byte[]> PdfData(string html, bool landscape, JObj margins) => WithPage(html, 800, async w => {
      var m = Margins(margins);
      var r = await w.CallDevToolsProtocolMethodAsync("Page.printToPDF", Json.Stringify(new JObj {
        { "landscape", landscape }, { "printBackground", true }, { "preferCSSPageSize", true }, { "paperWidth", 8.27 }, { "paperHeight", 11.69 },
        { "marginTop", m.Num("top") }, { "marginBottom", m.Num("bottom") }, { "marginLeft", m.Num("left") }, { "marginRight", m.Num("right") },
      }));
      return Convert.FromBase64String(((JObj)Json.Parse(r)).Str("data"));
    });

    /// HTML のページ全体 (見えていない下のほうも) を 1 枚の PNG にする
    const int MaxImageHeight = 16000;
    Task<(byte[] png, bool clipped)> CaptureWholePage(string html, double width) => WithPage(html, (int)Math.Round(width <= 0 ? 1000 : width), async w => {
      var metrics = Json.Parse(await w.CallDevToolsProtocolMethodAsync("Page.getLayoutMetrics", "{}")) as JObj;
      var content = metrics?.Obj("cssContentSize") ?? metrics?.Obj("contentSize") ?? new JObj();
      double cw = content.Num("width", width), ch = content.Num("height", 600);
      try {
        // 短い文書は、ウインドウの高さではなく本文の高さに合わせる
        var doc = (JObj)Json.Parse(await w.CallDevToolsProtocolMethodAsync("DOM.getDocument", "{\"depth\":1}"));
        var body = (JObj)Json.Parse(await w.CallDevToolsProtocolMethodAsync("DOM.querySelector", Json.Stringify(new JObj { { "nodeId", doc.Obj("root")["nodeId"] }, { "selector", "body" } })));
        var box = (JObj)Json.Parse(await w.CallDevToolsProtocolMethodAsync("DOM.getBoxModel", Json.Stringify(new JObj { { "nodeId", body["nodeId"] } })));
        var bh = box.Obj("model")?.Num("height") ?? 0;
        if (bh > 0) ch = bh;
      } catch { } // 取れなければページ全体の高さを使う
      var height = Math.Max(1, Math.Min(MaxImageHeight, Math.Ceiling(ch)));
      var r = await w.CallDevToolsProtocolMethodAsync("Page.captureScreenshot", Json.Stringify(new JObj {
        { "format", "png" }, { "captureBeyondViewport", true }, { "fromSurface", true },
        { "clip", new JObj { { "x", 0.0 }, { "y", 0.0 }, { "width", Math.Max(1, Math.Ceiling(cw)) }, { "height", height }, { "scale", 1.0 } } },
      }));
      return (Convert.FromBase64String(((JObj)Json.Parse(r)).Str("data")), ch > MaxImageHeight);
    }, true);

    static string XmlEscape(string s) =>
      Regex.Replace(s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;"), "[\u0000-\u0008\u000B\u000C\u000E-\u001F]", "");

    /// 段落の並び [{ text, align, indent }] → .docx の中身 (main.js の docxData と同じ)
    public static byte[] DocxData(List<object> paragraphs, string fontName) {
      var font = string.IsNullOrEmpty(fontName) ? "ＭＳ 明朝" : fontName;
      var body = new StringBuilder();
      foreach (var p in paragraphs.OfType<JObj>()) {
        var align = p.Str("align");
        var jc = align == "center" ? "<w:jc w:val=\"center\"/>" : align == "right" ? "<w:jc w:val=\"right\"/>" : "";
        var ind = p.Bool("indent") ? "<w:ind w:firstLineChars=\"100\" w:firstLine=\"210\"/>" : "";
        var runs = string.Join("<w:r><w:tab/></w:r>", p.Str("text").Split('\t').Select(t => $"<w:r><w:t xml:space=\"preserve\">{XmlEscape(t)}</w:t></w:r>"));
        body.Append($"<w:p><w:pPr>{jc}{ind}</w:pPr>{runs}</w:p>");
      }
      var document = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        + "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>" + body
        + "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1701\" w:right=\"1701\" w:bottom=\"1701\" w:left=\"1701\" w:header=\"851\" w:footer=\"992\" w:gutter=\"0\"/></w:sectPr>"
        + "</w:body></w:document>";
      var f = XmlEscape(font);
      var styles = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        + "<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:docDefaults><w:rPrDefault><w:rPr>"
        + $"<w:rFonts w:ascii=\"{f}\" w:hAnsi=\"{f}\" w:eastAsia=\"{f}\"/><w:sz w:val=\"21\"/><w:szCs w:val=\"21\"/><w:lang w:val=\"en-US\" w:eastAsia=\"ja-JP\"/>"
        + "</w:rPr></w:rPrDefault></w:docDefaults></w:styles>";
      Zip.Entry E(string name, string data) => new Zip.Entry { Name = name, Data = new UTF8Encoding(false).GetBytes(data) };
      return Zip.Make(new[] {
        E("[Content_Types].xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/></Types>"),
        E("_rels/.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"),
        E("word/_rels/document.xml.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>"),
        E("word/document.xml", document),
        E("word/styles.xml", styles),
      });
    }

    static void CopyImage(byte[] png) {
      using (var ms = new MemoryStream(png))
      using (var bmp = new Bitmap(ms)) {
        var data = new DataObject();
        data.SetData(DataFormats.Bitmap, true, new Bitmap(bmp));
        data.SetData("PNG", false, new MemoryStream(png));
        Clipboard.SetDataObject(data, true);
      }
    }

    void RegisterPrint() {
      OnAsync("exportPDF", async a => {
        var o = O(a, 0);
        try {
          var data = await PdfData(o.Str("html"), o.Bool("landscape"), o.Obj("margins"));
          Store.WriteAtomic(o.Str("path"), data);
          return new JObj { { "status", "ok" } };
        } catch (Exception e) { return Fail(e); }
      });
      OnAsync("print", async a => {
        var o = O(a, 0);
        try {
          string printer;
          short copies;
          using (var d = new PrintDialog { UseEXDialog = true, AllowSomePages = false }) {
            if (d.ShowDialog(form) != DialogResult.OK) return new JObj { { "status", "ok" } };
            printer = d.PrinterSettings.PrinterName;
            copies = d.PrinterSettings.Copies;
          }
          await WithPage(o.Str("html"), 800, async w => {
            var s = form.Env.CreatePrintSettings();
            s.PrinterName = printer;
            s.Copies = Math.Max(1, (int)copies);
            s.Orientation = o.Bool("landscape") ? CoreWebView2PrintOrientation.Landscape : CoreWebView2PrintOrientation.Portrait;
            s.ShouldPrintBackgrounds = true;
            s.PageWidth = 8.27;
            s.PageHeight = 11.69;
            var m = Margins(o.Obj("margins"));
            s.MarginTop = m.Num("top"); s.MarginBottom = m.Num("bottom"); s.MarginLeft = m.Num("left"); s.MarginRight = m.Num("right");
            var st = await w.PrintAsync(s);
            if (st != CoreWebView2PrintStatus.Succeeded) throw new UserError("印刷できませんでした (" + st + ")");
            return true;
          });
          return new JObj { { "status", "ok" } };
        } catch (Exception e) { return Fail(e); }
      });
      OnAsync("screenshot", async a => {
        var o = O(a, 0);
        try {
          byte[] png;
          bool clipped = false;
          if (o.Str("mode") == "visible") {
            var ms = new MemoryStream();
            var cap = Web.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, ms);
            if (await Task.WhenAny(cap, Task.Delay(8000)) != cap) throw new UserError("画像にするのに時間がかかりすぎました。ウインドウを表示した状態で、もう一度試してください。");
            png = ms.ToArray();
            var rect = o.Obj("rect");
            if (rect != null) {
              var k = form.DeviceDpi / 96.0;
              using (var src = new Bitmap(new MemoryStream(png))) {
                var r = Rectangle.Intersect(new Rectangle((int)Math.Round(rect.Num("x") * k), (int)Math.Round(rect.Num("y") * k), (int)Math.Round(rect.Num("width") * k), (int)Math.Round(rect.Num("height") * k)), new Rectangle(0, 0, src.Width, src.Height));
                if (r.Width > 0 && r.Height > 0) {
                  using (var part = src.Clone(r, src.PixelFormat)) {
                    var outs = new MemoryStream();
                    part.Save(outs, ImageFormat.Png);
                    png = outs.ToArray();
                  }
                }
              }
            }
          } else {
            var whole = CaptureWholePage(o.Str("html"), o.Num("width", 1000));
            if (await Task.WhenAny(whole, Task.Delay(20000)) != whole) throw new UserError("画像にするのに時間がかかりすぎました。ウインドウを表示した状態で、もう一度試してください。");
            (png, clipped) = await whole;
          }
          int width, height;
          using (var bmp = new Bitmap(new MemoryStream(png))) { width = bmp.Width; height = bmp.Height; }
          if (o.Str("action") == "base64") {
            // リンクで公開するときの画像: 大きすぎれば縮める (幅 1400・高さ 12000 まで、5.5 MB まで)
            png = ShrinkPng(png, 1400, 12000, 5500000);
            if (png == null) return new JObj { { "status", "error" }, { "code", "tooLarge" }, { "message", "too large" } };
            return new JObj { { "status", "ok" }, { "base64", Convert.ToBase64String(png) } };
          }
          if (o.Str("action") == "copy") CopyImage(png);
          else Store.WriteAtomic(o.Str("path"), png);
          return new JObj { { "status", "ok" }, { "width", (double)width }, { "height", (double)height }, { "clipped", clipped } };
        } catch (Exception e) { return Fail(e); }
      });
      OnBg("exportDocx", a => {
        var o = O(a, 0);
        try {
          Store.WriteAtomic(o.Str("path"), DocxData(o.Arr("paragraphs") ?? new List<object>(), o.Str("font")));
          return new JObj { { "status", "ok" } };
        } catch (Exception e) { return Fail(e); }
      });
    }
  
    static byte[] ShrinkPng(byte[] png, int maxW, int maxH, int limit) {
      using (var src = new Bitmap(new MemoryStream(png))) {
        double scale = Math.Min(1.0, (double)maxW / Math.Max(1, src.Width));
        for (int i = 0; i < 5; i++) {
          int w = Math.Max(1, (int)(src.Width * scale)), fullH = Math.Max(1, (int)(src.Height * scale)), h = Math.Min(maxH, fullH);
          byte[] data;
          if (scale >= 1 && h == src.Height) data = png;
          else {
            using (var dst = new Bitmap(w, h))
            using (var g = Graphics.FromImage(dst)) {
              g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
              g.DrawImage(src, new Rectangle(0, 0, w, fullH)); // 高さが上限を超えるぶんは下を切る
              var ms = new MemoryStream();
              dst.Save(ms, ImageFormat.Png);
              data = ms.ToArray();
            }
          }
          if (data.Length <= limit) return data;
          scale *= 0.7;
        }
        return null;
      }
    }
}
}
