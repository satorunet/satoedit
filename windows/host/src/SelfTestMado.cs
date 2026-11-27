using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace SatoEdit {
  /// 自己点検: ツールバー (最初の並び・名前)、左の一覧 (はじめは出さない)、窓割り、巨大ファイル
  partial class SelfTest {
    async Task Mouse(string type, double x, double y, int buttons = 1) {
      await Web.CallDevToolsProtocolMethodAsync("Input.dispatchMouseEvent", Json.Stringify(new JObj {
        { "type", type }, { "x", x }, { "y", y }, { "button", "left" }, { "buttons", (double)buttons }, { "clickCount", (double)(type == "mouseMoved" ? 0 : 1) },
      }));
    }

    async Task RunMadoSteps(string work) {
      await Step("toolbarDefault", async () => {
        // 前の版で覚えた並びは使わず、新しい最初の並びにする (覚える設定の名前を変えた)
        await Js("(() => { __app.setPref(__app.TOOLBAR_PREF, null); })()");
        await Wait(300);
        var labels = await Js("Array.from(document.querySelectorAll('#toolbar .tb-button')).map(b => b.querySelector('.tb-label').textContent).join(',')") as string;
        var shown = await Js("(() => { const b = document.querySelector('#toolbar .tb-button'); const l = b.querySelector('.tb-label'), s = b.querySelector('svg'); return l.getBoundingClientRect().top > s.getBoundingClientRect().top + 8; })()");
        Expect((labels ?? "").StartsWith("新規作成,開く,保存,元に戻す,やり直し,検索,"), "ツールバーの最初の並び: " + labels);
        Expect(shown is bool b && b, "ツールバーの名前が絵の下にない");
        var def = Store.PrefDefaults["libraryVisible"];
        Expect(def is bool lv && !lv, "左の一覧の既定が「出さない」でない");
        Expect(Store.PrefDefaults["madoEnabled"] is bool me && me, "窓割りの既定が入でない");
        await Shot("10-toolbar");
        return new JObj { { "labels", labels }, { "libraryVisibleDefault", def } };
      });

      await Step("mado", async () => {
        await Js("(async () => { for (const x of __app.tabs.slice()) await __app.closeTab(x, { noAsk: true }); __app.active.editor.setText('1 つ目の文書\\n左の画面', false); })()");
        foreach (var n in new[] { "a", "b" }) File.WriteAllText(Path.Combine(work, "mado-" + n + ".txt"), n + " の文書\n" + string.Join("\n", Enumerable.Range(1, 40).Select(i => n + " " + i)) + "\n", new UTF8Encoding(false));
        await Js("(async () => { await __app.openPath(" + Q(Path.Combine(work, "mado-a.txt")) + "); __app.newTab(); await __app.openPath(" + Q(Path.Combine(work, "mado-b.txt")) + "); })()");
        await Wait(400);
        form.Activate();
        form.View.Focus();
        await Js("__app.focusEditor()");
        // Ctrl+Alt+→: タブを左右に並べる
        await Key("ArrowRight", "ArrowRight", 0x27, 3);
        await Wait(600);
        var side = await Js(@"(() => { const ps = Array.from(document.querySelectorAll('#mado-root .mado-pane')); return { panes: ps.length, on: document.getElementById('editors').classList.contains('mado-on'), dir: __app.mado.root && __app.mado.root.dir,
          titles: ps.map(p => p.querySelector('.mado-title').textContent).join('|'), widths: ps.map(p => Math.round(p.getBoundingClientRect().width)).join(','), tops: ps.map(p => Math.round(p.getBoundingClientRect().top)).join(','),
          focused: (document.querySelector('.mado-pane.focused .mado-title') || {}).textContent, active: __app.active.name }; })()") as JObj;
        Expect(side?.Num("panes") == 3 && side?.Str("dir") == "row", "Ctrl+Alt+→ で 3 つの画面が左右に並ばない: " + Json.Stringify(side));
        await Shot("11-mado-side");
        // Ctrl+Alt+] で次の画面へ。そこに打った字は、その画面の文書に入る
        await Key("]", "BracketRight", 0xDD, 3);
        await Wait(300);
        var afterNext = await Js("__app.active.name") as string;
        await Js("__app.focusEditor()");
        await Type("★");
        await Wait(300);
        var typedIn = await Js("__app.tabs.filter(t => t.editor.getText().includes('★')).map(t => t.name).join(',')") as string;
        Expect(typedIn == afterNext, "次の画面に打った字が、その画面の文書に入らない: " + typedIn + " / " + afterNext);
        // フォーカスのある画面で、ツールバー・ステータスバーが動く (ステータスバーの行数はその文書のもの)
        var status = await Js("document.querySelector('#status-cells [data-id=\"total\"]').textContent") as string;
        // Ctrl+Alt+↓: 上下に並べる
        await Key("ArrowDown", "ArrowDown", 0x28, 3);
        await Wait(500);
        var stacked = await Js("({ dir: __app.mado.root.dir, tops: Array.from(document.querySelectorAll('#mado-root .mado-pane')).map(p => Math.round(p.getBoundingClientRect().top)).join(',') })") as JObj;
        Expect(stacked?.Str("dir") == "col", "Ctrl+Alt+↓ で上下に並ばない");
        await Shot("12-mado-stacked");
        // 見出しの × でその画面の文書を閉じる (書き換えているので、保存するか聞かれる → 保存しない)
        await Js("(() => { const p = Array.from(document.querySelectorAll('#mado-root .mado-pane')).find(x => x.tab === __app.active); p.querySelector('.mado-close').click(); })()");
        await Wait(400);
        var asked = await Js("(document.querySelector('.modal-title') || {}).textContent || ''") as string;
        await Js("(() => { const b = Array.from(document.querySelectorAll('.modal-buttons button')).find(x => /保存しない|Don/.test(x.textContent)); if (b) b.click(); })()");
        await Wait(500);
        var afterClose = await Js("({ panes: document.querySelectorAll('#mado-root .mado-pane').length, tabs: __app.tabs.length, active: __app.active.name, inMado: __app.mado.has(__app.active) })") as JObj;
        Expect(afterClose?.Num("panes") == 2 && afterClose?.Num("tabs") == 2, "× で画面が閉じない: " + Json.Stringify(afterClose));
        // 「＋」は、いつも新しいタブ (並びには入れない)
        await Js("document.getElementById('tab-add').click()");
        await Wait(300);
        var plus = await Js("({ tabs: __app.tabs.length, inMado: __app.mado.has(__app.active), shown: document.getElementById('editors').classList.contains('mado-on') })") as JObj;
        Expect(plus?.Num("tabs") == 3 && !plus.Bool("inMado") && !plus.Bool("shown"), "＋ が新しいタブにならない: " + Json.Stringify(plus));
        // タブを、並べた画面の右の端へドラッグ → 離す前に入る所を見せ、離すとそこに並ぶ
        await Js("__app.activate(__app.tabs[0])");
        await Wait(300);
        var geo = await Js(@"(() => { const tab = document.querySelectorAll('#tabs .tab')[2].getBoundingClientRect(); const p = document.querySelector('#mado-root .mado-pane').getBoundingClientRect();
          return { tx: tab.left + tab.width / 2, ty: tab.top + tab.height / 2, px: p.right - 25, py: p.top + p.height / 2 }; })()") as JObj;
        await Mouse("mousePressed", geo.Num("tx"), geo.Num("ty"));
        for (int i = 1; i <= 8; i++) await Mouse("mouseMoved", geo.Num("tx") + (geo.Num("px") - geo.Num("tx")) * i / 8, geo.Num("ty") + (geo.Num("py") - geo.Num("ty")) * i / 8);
        await Wait(200);
        var preview = await Js("(() => { const d = document.querySelector('.mado-drop'); const r = d.getBoundingClientRect(); return { shown: !d.hidden, w: Math.round(r.width), h: Math.round(r.height) }; })()") as JObj;
        await Shot("13-mado-drag");
        await Mouse("mouseReleased", geo.Num("px"), geo.Num("py"));
        await Wait(500);
        var dropped = await Js("({ panes: document.querySelectorAll('#mado-root .mado-pane').length, tree: JSON.stringify(__app.mado.root, (k, v) => k === 'tab' ? v.name : (k === 'sizes' ? undefined : v)), previewHidden: document.querySelector('.mado-drop').hidden })") as JObj;
        Expect(preview != null && preview.Bool("shown") && dropped?.Num("panes") == 3, "タブをドラッグして並べられない: " + Json.Stringify(preview) + " " + Json.Stringify(dropped));
        await Shot("14-mado-dropped");
        // メニュー (表示 > 窓割り) に項目があるか
        var menuItems = new System.Collections.Generic.List<object>();
        void Walk(ToolStripItemCollection items) { foreach (var it in items.OfType<ToolStripMenuItem>()) { if (it.ShortcutKeyDisplayString != null && it.ShortcutKeyDisplayString.StartsWith("Ctrl+Alt+")) menuItems.Add(it.Text + " " + it.ShortcutKeyDisplayString); Walk(it.DropDownItems); } }
        Walk(form.MainMenuStrip.Items);
        // Ctrl+Alt+↑: 並べるのをやめる
        await Key("ArrowUp", "ArrowUp", 0x26, 3);
        await Wait(400);
        var unsplit = await Js("({ active: __app.mado.active, on: document.getElementById('editors').classList.contains('mado-on'), views: document.querySelectorAll('#editors > .tab-view').length })") as JObj;
        Expect(unsplit != null && !unsplit.Bool("active") && !unsplit.Bool("on"), "Ctrl+Alt+↑ で並びがやめられない");
        // 追加機能で切れる (切ると並びをやめ、メニューから消える)
        await Js("__app.run('mado.sideBySide')");
        await Wait(300);
        await Js("__app.setPref('madoEnabled', false)");
        await Wait(400);
        var off = await Js("({ active: __app.mado.active })") as JObj;
        int offItems = 0;
        void Count(ToolStripItemCollection items) { foreach (var it in items.OfType<ToolStripMenuItem>()) { if (it.ShortcutKeyDisplayString == "Ctrl+Alt+Right") offItems++; Count(it.DropDownItems); } }
        Count(form.MainMenuStrip.Items);
        Expect(off != null && !off.Bool("active") && offItems == 0, "窓割りを切っても並びが残る・メニューに残る");
        await Js("__app.setPref('madoEnabled', true)");
        await Wait(300);
        await Js("(async () => { for (const x of __app.tabs.slice()) await __app.closeTab(x, { noAsk: true }); })()");
        return new JObj { { "side", side }, { "afterNext", afterNext }, { "typedIn", typedIn }, { "status", status }, { "stacked", stacked }, { "asked", asked }, { "afterClose", afterClose },
          { "plus", plus }, { "preview", preview }, { "dropped", dropped }, { "menu", menuItems }, { "unsplit", unsplit }, { "off", off }, { "offMenuItems", (double)offItems } };
      });

      await Step("hugeFile", async () => {
        // 40 MB ほどのファイル (行ごとに番号)。開くと先頭の 8 MB だけを読む
        var file = Path.Combine(work, "huge.txt");
        string LineText(int i) => "行 " + i.ToString("D7") + " あいうえおかきくけこ ABCDEFGHIJ";
        await Task.Run(() => {
          using (var w = new StreamWriter(file, false, new UTF8Encoding(false), 1 << 20)) {
            for (int i = 1; i <= 950000; i++) { w.Write(LineText(i)); w.Write('\n'); }
          }
        });
        long size = new FileInfo(file).Length;
        var opened = await Js("(async () => { const t0 = performance.now(); const tab = await __app.openPath(" + Q(file) + "); await new Promise(r => requestAnimationFrame(() => r())); return { ms: Math.round(performance.now() - t0), part: tab.partial, lines: tab.editor.view.state.doc.lines, first: tab.editor.view.state.doc.line(1).text, status: document.getElementById('status-notes').textContent }; })()") as JObj;
        var part = opened?.Obj("partial") ?? opened?.Obj("part");
        Expect(part != null && part.Num("offset") == 0 && part.Num("length") <= 9 * 1048576 && part.Num("fileSize") == size, "巨大ファイルが一部分だけで開かない: " + Json.Stringify(opened));
        Expect((opened?.Str("status") ?? "").Contains("大きなファイル"), "ステータスバーに大きなファイルの表示がない");
        await Shot("15-huge-open");
        // いちばん下までスクロール → 続きを読む。いちばん上に見えていた行は、画面の同じ所に残る
        var slide = await Js(@"(async () => { const tab = __app.active, v = tab.editor.view, sc = v.scrollDOM; const wait = ms => new Promise(r => setTimeout(r, ms));
          const orig = __app.hugeLoad; let at = null;
          __app.hugeLoad = function (t, o, shift) { if (o.topLine !== undefined) at = { text: t.editor.view.state.doc.line(o.topLine + 1).text, shift: Math.round(shift) }; return orig.apply(this, arguments); };
          const before = tab.partial;
          sc.scrollTop = sc.scrollHeight; await wait(1500);
          __app.hugeLoad = orig;
          const top = v.lineBlockAtHeight(sc.scrollTop);
          return { before, after: tab.partial, slideTop: at, topText: v.state.doc.lineAt(top.from).text, topShift: Math.round(sc.scrollTop - top.top), status: document.getElementById('status-notes').textContent }; })()") as JObj;
        Expect(slide != null && slide.Obj("slideTop") != null && slide.Obj("slideTop").Str("text") == slide.Str("topText"), "読み直したあと、いちばん上の行が同じ所に残らない: " + Json.Stringify(slide));
        var after = slide?.Obj("after");
        Expect(after != null && after.Num("offset") > 0, "スクロールしても続きを読まない: " + Json.Stringify(slide));
        // 位置へ移動 (50%)
        var jump = await Js(@"(async () => { const tab = __app.active; await __app.hugeLoad(tab, { part: tab.partial, fraction: 0.5, back: 0.5 }, 0); await new Promise(r => setTimeout(r, 500));
          const v = tab.editor.view; return { part: tab.partial, caretLine: v.state.doc.lineAt(v.state.selection.main.head).text, first: v.state.doc.line(1).text, status: document.getElementById('status-notes').textContent }; })()") as JObj;
        var jp = jump?.Obj("part");
        Expect(jp != null && Math.Abs(jp.Num("offset") + jp.Num("length") / 2 - size / 2.0) < size * 0.02, "50% の位置へ移動できない: " + Json.Stringify(jump));
        await Shot("16-huge-jump");
        // 書き換えて保存すると、その範囲だけが入る (前後はそのまま)
        var firstLine = jump?.Str("first") ?? "";
        var saved = await Js(@"(async () => { const tab = __app.active; tab.editor.view.dispatch({ changes: { from: 0, insert: '★追加した行\n' } }); const ok = await __app.save(tab); return { ok, part: tab.partial }; })()") as JObj;
        await Wait(300);
        long size2 = new FileInfo(file).Length;
        var marker = Encoding.UTF8.GetBytes("★追加した行\n");
        var wantAt = (long)jp.Num("offset");
        var got = PartialFile.Read(file, new PartialFile.Part(wantAt, marker.Length + Encoding.UTF8.GetByteCount(firstLine), size2));
        var gotText = Encoding.UTF8.GetString(got);
        var lastLine = Encoding.UTF8.GetString(PartialFile.Read(file, new PartialFile.Part(size2 - Encoding.UTF8.GetByteCount(LineText(950000)) - 1, Encoding.UTF8.GetByteCount(LineText(950000)) + 1, size2)));
        Expect(size2 == size + marker.Length && gotText == "★追加した行\n" + firstLine && lastLine == LineText(950000) + "\n" && saved != null && saved.Bool("ok"),
          "巨大ファイルの保存がおかしい: " + size + " → " + size2 + " [" + gotText + "] [" + lastLine + "]");
        // 書き換えて保存していないうちは、範囲を動かさない (知らせを 1 回出す)
        var dirty = await Js(@"(async () => { const tab = __app.active, v = tab.editor.view, sc = v.scrollDOM; v.dispatch({ changes: { from: 0, insert: 'x' } }); const p0 = JSON.stringify(tab.partial);
          sc.scrollTop = sc.scrollHeight; sc.dispatchEvent(new Event('scroll')); await new Promise(r => setTimeout(r, 800));
          const kept = JSON.stringify(tab.partial) === p0, warned = !!tab.hugeWarned; v.dispatch({ changes: { from: 0, to: 1 } }); return { kept, warned }; })()") as JObj;
        Expect(dirty != null && dirty.Bool("kept") && dirty.Bool("warned"), "保存していないのに範囲が動いた・知らせが出ない: " + Json.Stringify(dirty));
        await Shot("17-huge-dirty");
        await Js("(async () => { for (const x of __app.tabs.slice()) await __app.closeTab(x, { noAsk: true }); })()");
        try { File.Delete(file); } catch { }
        return new JObj { { "size", (double)size }, { "opened", opened }, { "slide", slide }, { "jump", jump }, { "saved", saved }, { "size2", (double)size2 }, { "dirty", dirty } };
      });
    }
  }
}
