using System;
using System.Threading.Tasks;

namespace SatoEdit {
  /// 自己点検: 速さ (大きな文書で打ったときの時間) と、選択の見た目
  partial class SelfTest {
    async Task RunPerfSteps(string work) {
      // 大きな文書で 1 字打つのにかかる時間 (ms)。打つ → 画面に出す (CodeMirror の測り直しと、ページの組み直しまで) を測る。
      // 1.5 MB の JavaScript (色分けあり) の真ん中と最後、20 MB のテキストの真ん中
      await Step("typingLatency", async () => {
        var r = await Js(@"(async () => {
          const app = __app, out = {};
          const frame = () => new Promise(res => requestAnimationFrame(() => setTimeout(res, 0)));
          const stats = list => { const s = list.slice().sort((a, b) => a - b); return { avg: +(list.reduce((a, b) => a + b, 0) / list.length).toFixed(2), median: +s[s.length >> 1].toFixed(2), max: +s[s.length - 1].toFixed(2) }; };
          async function measure(text, language, where) {
            const t0 = performance.now();
            const tab = app.newTab({ text });
            if (language) app.run('doc.language:' + language);
            await frame();
            const open = performance.now() - t0;
            const v = tab.editor.view;
            const at = where === 'end' ? v.state.doc.length : Math.floor(v.state.doc.length / 2);
            v.dispatch({ selection: { anchor: at }, scrollIntoView: true });
            v.focus();
            await frame();
            const sync = [], withFrame = [];
            for (let i = 0; i < 50; i++) {
              const t = performance.now();
              v.dispatch(Object.assign(v.state.replaceSelection(i % 6 === 5 ? ' ' : 'value'[i % 6]), { userEvent: 'input.type', scrollIntoView: true }));
              if (v.measure) v.measure();
              document.body.offsetHeight;
              sync.push(performance.now() - t);
              await frame();
              withFrame.push(performance.now() - t);
            }
            const colored = tab.el.querySelectorAll('.tok-keyword').length;
            await app.closeTab(tab, { noAsk: true });
            return { open: +open.toFixed(1), keystroke: stats(sync), keystrokeWithFrame: stats(withFrame), colored };
          }
          const unit = '// コメント\nfunction add(a, b) {\n  const s = ""文字列"" + a; /* ブロック */\n  return a + b + 42;\n}\n';
          const big = unit.repeat(Math.ceil(1500000 / unit.length));
          const lang = app.profiles.find(p => p.name.startsWith('JavaScript')).name;
          out.js1_5MB_mid = await measure(big, lang, 'mid');
          out.js1_5MB_end = await measure(big, lang, 'end');
          // 原稿用紙 (40 枚ぶん) の真ん中で打つ
          {
            const tab = app.newTab({ text: ('　春の遠足の作文です。先週の金曜日、学校の遠足で動物園に行きました。\n').repeat(450) });
            app.setPaperMode(tab, 1, { remember: false });
            await frame();
            tab.paper.focus();
            tab.paper.select(8000, 8000);
            await frame();
            const sync = [];
            for (let i = 0; i < 30; i++) {
              const t = performance.now();
              tab.paper.replaceSelection('あ');
              document.body.offsetHeight;
              sync.push(performance.now() - t);
              await frame();
            }
            out.genko40sheets = { sheets: document.querySelectorAll('.tab-view.active .genko-sheet').length, keystroke: stats(sync) };
            app.setPaperMode(tab, 0, { remember: false });
            await app.closeTab(tab, { noAsk: true });
          }
          out.plain20MB_mid = await measure('これは大きなテキストの行です。The quick brown fox 0123456789\n'.repeat(Math.ceil(20e6 / 52)), '', 'mid');
          return out;
        })()");
        var o = r as JObj;
        foreach (var k in new[] { "js1_5MB_mid", "js1_5MB_end", "plain20MB_mid" }) {
          var avg = o?.Obj(k)?.Obj("keystroke")?.Num("avg") ?? 9999;
          Expect(avg < 50, "大きな文書で 1 字打つ時間 (" + k + "): 平均 " + avg + " ms");
        }
        Expect((o?.Obj("js1_5MB_end")?.Num("colored") ?? 0) > 0, "大きな文書の最後でも色分けしている");
        return r;
      });

      // 選択は字のあるところだけを塗る (行の右端までの空き・改行のぶんは塗らない)
      await Step("selectionPaint", async () => {
        var r = await Js(@"(async () => {
          const app = __app, out = {};
          const frame = () => new Promise(res => requestAnimationFrame(() => setTimeout(res, 0)));
          const tab = app.newTab({ text: 'ab\nこれは長い行です。これは長い行です。\n\nxyz\n' });
          await frame();
          const v = tab.editor.view;
          v.dispatch({ selection: { anchor: 1, head: 15 } });
          v.focus();
          await frame(); await frame();
          const end1 = v.coordsAtPos(2, -1);
          const line1 = v.lineBlockAt(0);
          const marks = Array.from(tab.el.querySelectorAll('.cm-sel-text'));
          const top = v.documentTop;
          const onLine1 = marks.filter(m => { const r = m.getBoundingClientRect(); return r.top < top + line1.bottom - 1 && r.bottom > top + line1.top + 1; });
          out.marks = marks.length;
          out.text = marks.map(m => m.textContent).join('|');
          out.line1Right = onLine1.length ? Math.max(...onLine1.map(m => m.getBoundingClientRect().right)) : -1;
          out.line1TextEnd = end1 ? end1.right : -1;
          out.layerHidden = getComputedStyle(tab.el.querySelector('.cm-selectionLayer') || document.body).display === 'none';
          out.selected = tab.editor.selectionText();
          // 空の行を含めて選んでも、空の行は塗らない
          v.dispatch({ selection: { anchor: 0, head: v.state.doc.length } });
          await frame();
          out.emptyLinePainted = Array.from(tab.el.querySelectorAll('.cm-line')).filter(l => !l.textContent && l.querySelector('.cm-sel-text')).length;
          // 原稿用紙: 選んだ字のマスだけ (改行・空の列は塗らない)
          app.setPaperMode(tab, 1, { remember: false });
          await frame();
          tab.paper.setText('あいう\n\nかきく');
          tab.paper.focus();
          tab.paper.select(0, 9);
          await frame();
          out.genkoSel = document.querySelectorAll('.tab-view.active .gk.sel').length;
          out.genkoSelText = tab.paper.selectionText();
          app.setPaperMode(tab, 0, { remember: false });
          await app.closeTab(tab, { noAsk: true });
          return out;
        })()");
        var o = r as JObj;
        Expect(o != null && o.Bool("layerHidden"), "行の右端まで伸びる選択の四角を出していない");
        Expect(o != null && o.Num("marks") > 0 && o.Num("line1Right") > 0 && o.Num("line1Right") <= o.Num("line1TextEnd") + 1, "選択は 1 行目の字の終わりまで: " + Json.Stringify(r));
        Expect(o != null && o.Str("selected") == "b\nこれは長い行です。これは", "選んだ文字はそのまま: " + o?.Str("selected"));
        Expect(o != null && o.Num("emptyLinePainted") == 0, "空の行は塗らない");
        Expect(o != null && o.Num("genkoSel") == 6, "原稿用紙は選んだ字のマスだけ塗る (6 マス): " + o?.Num("genkoSel"));
        await Shot("perf-selection");
        return r;
      });
    }
  }
}
