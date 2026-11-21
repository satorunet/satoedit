// 共同編集 (Mac 版と同じ決まりで、Mac とも一緒に編集できる)。
// ホスト: 自分の PC で待ち受け、参加の申し込みを 1 人ずつ承認する。全員の変更の順番はホストが決める。
// ゲスト: 「アドレス:ポート」と共有コードで参加する。承認されると、ホストの文書が新しいタブで開く。
import { h, modal, alertBox, toast } from './dialogs';
import { remoteAnnotation } from './editor';
import ot from '../../shared/collabot';
import i18n from '../../shared/i18n';

const { t } = i18n;
const PROTOCOL_VERSION = 1;
const PALETTE = ['#F27333', '#33B3F2', '#8CD94D', '#E659BF', '#FACC33', '#9980F2'];
const colorOf = id => PALETTE[Math.abs(id) % PALETTE.length];

export class CollabSession {
  constructor(app, role, name) {
    this.app = app;
    this.role = role;
    this.myName = name;
    this.myID = role === 'host' ? 0 : -1;
    this.users = new Map(); // id → { id, name }
    this.cursors = new Map(); // id → { loc, len }
    this.active = true;
    this.tab = null;
    // ホスト
    this.peers = new Map(); // 接続の番号 → { conn, id, name, approved, address }
    this.server = new ot.OTServer();
    this.nextID = 1;
    this.pending = [];
    this.approvalShowing = false;
    // ゲスト
    this.client = null;
    this.onWelcome = null;
    this.onJoinFailed = null;
    this.decryptedAny = false;
    if (role === 'host') this.users.set(0, { id: 0, name });
  }

  // ---------- 通信の知らせ (app.js から渡ってくる) ----------

  opened(conn, address) {
    if (this.role === 'host') {
      this.peers.set(conn, { conn, id: -1, name: '', approved: false, address });
    } else {
      this.send({ t: 'hello', v: PROTOCOL_VERSION, name: this.myName });
    }
  }

  message(conn, msg) {
    this.decryptedAny = true;
    if (this.role === 'host') this.hostReceive(conn, msg); else this.guestReceive(msg);
  }

  closed(conn, info) {
    if (this.role === 'host') { this.peerLeft(conn); return; }
    if (!this.active) return;
    if (!this.client) {
      const fail = this.onJoinFailed;
      this.onJoinFailed = null;
      if (fail) fail(info && !info.decryptedAny ? t('つながりません。アドレスとコードを確認してください。') : t('つながりません。アドレスを確認してください。'));
    } else {
      this.system(t('接続が切れました。'));
    }
    this.active = false;
    for (const id of Array.from(this.users.keys())) if (id !== this.myID) this.users.delete(id);
    this.cursors.clear();
    this.changed();
  }

  // ---------- ホスト ----------

  hostReceive(conn, msg) {
    const peer = this.peers.get(conn);
    if (!peer) return;
    const type = typeof msg.t === 'string' ? msg.t : '';
    if (!peer.approved) {
      if (type !== 'hello' || peer.id !== -1) return;
      peer.name = String(msg.name || t('名無し')).slice(0, 40);
      peer.id = -2; // 承認待ち
      this.pending.push(peer);
      this.showNextApproval();
      return;
    }
    if (type === 'op') {
      const o = opFrom(msg);
      if (!o || !Number.isInteger(msg.rev)) return;
      const r = this.server.receive(o, msg.rev);
      this.applyRemote(r.op);
      this.broadcast({ t: 'op', rev: r.revision, author: peer.id, loc: r.op.loc, len: r.op.len, text: r.op.text });
    } else if (type === 'cursor') {
      if (!Number.isInteger(msg.loc) || !Number.isInteger(msg.len)) return;
      this.cursors.set(peer.id, { loc: msg.loc, len: msg.len });
      this.renderCursors();
      this.broadcast({ t: 'cursor', author: peer.id, loc: msg.loc, len: msg.len }, conn);
    } else if (type === 'chat') {
      if (typeof msg.text !== 'string') return;
      const text = msg.text.slice(0, 2000);
      this.chat(this.users.get(peer.id), text);
      this.broadcast({ t: 'chat', author: peer.id, text }, conn);
    } else if (type === 'bye') {
      this.app.api.collabClose(conn);
    }
  }

  /// 参加の承認 (1 人ずつ確認する)
  async showNextApproval() {
    if (this.approvalShowing || !this.pending.length) return;
    const peer = this.pending.shift();
    if (!this.peers.has(peer.conn)) { this.showNextApproval(); return; }
    this.approvalShowing = true;
    this.app.api.attention();
    const ok = await modal({
      title: t('「{name}」が共同編集に参加しようとしています', { name: peer.name }),
      body: t('接続元: {address}\n承認すると、この文書が相手に見えます。', { address: peer.address }),
      buttons: [{ label: t('承認する'), value: true, primary: true }, { label: t('断る'), value: false, cancel: true }],
    });
    this.approvalShowing = false;
    if (ok && this.active && this.peers.has(peer.conn)) this.approve(peer);
    else {
      this.app.api.collabSend(peer.conn, { t: 'reject', reason: t('ホストが参加を断りました') });
      setTimeout(() => this.app.api.collabClose(peer.conn), 500);
    }
    this.showNextApproval();
  }

  approve(peer) {
    peer.id = this.nextID++;
    peer.approved = true;
    this.users.set(peer.id, { id: peer.id, name: peer.name });
    this.app.api.collabSend(peer.conn, {
      t: 'welcome', v: PROTOCOL_VERSION, id: peer.id, rev: this.server.revision,
      text: this.tab ? this.tab.editor.getText() : '', title: this.tab ? this.tab.name : '',
      users: Array.from(this.users.values()).map(u => ({ id: u.id, name: u.name })),
      cursors: Array.from(this.cursors.entries()).map(([author, c]) => ({ author, loc: c.loc, len: c.len })),
    });
    this.broadcast({ t: 'join', id: peer.id, name: peer.name }, peer.conn);
    this.system(t('{name} さんが参加しました', { name: peer.name }));
    this.changed();
    this.sendMyCursor();
  }

  peerLeft(conn) {
    const peer = this.peers.get(conn);
    this.peers.delete(conn);
    this.pending = this.pending.filter(p => p.conn !== conn);
    if (!peer || !peer.approved || !this.active) return;
    this.users.delete(peer.id);
    this.cursors.delete(peer.id);
    this.broadcast({ t: 'leave', id: peer.id });
    this.system(t('{name} さんが抜けました', { name: peer.name }));
    this.changed();
  }

  broadcast(msg, except) {
    for (const p of this.peers.values()) if (p.approved && p.conn !== except) this.app.api.collabSend(p.conn, msg);
  }

  // ---------- ゲスト ----------

  send(msg) { this.app.api.collabSend(0, msg); }

  guestReceive(msg) {
    switch (msg.t) {
      case 'welcome': {
        if (this.client || !Number.isInteger(msg.id) || !Number.isInteger(msg.rev)) return;
        this.myID = msg.id;
        this.client = new ot.OTClient(msg.rev);
        for (const u of Array.isArray(msg.users) ? msg.users : []) if (Number.isInteger(u.id) && typeof u.name === 'string') this.users.set(u.id, { id: u.id, name: u.name });
        for (const c of Array.isArray(msg.cursors) ? msg.cursors : []) if (Number.isInteger(c.author) && Number.isInteger(c.loc) && Number.isInteger(c.len)) this.cursors.set(c.author, { loc: c.loc, len: c.len });
        if (!this.users.has(this.myID)) this.users.set(this.myID, { id: this.myID, name: this.myName });
        const w = this.onWelcome;
        this.onWelcome = null;
        this.onJoinFailed = null;
        if (w) w(typeof msg.text === 'string' ? msg.text : '', typeof msg.title === 'string' ? msg.title : '');
        break;
      }
      case 'reject': {
        const fail = this.onJoinFailed;
        this.onJoinFailed = null;
        this.active = false;
        if (fail) fail(typeof msg.reason === 'string' ? msg.reason : t('参加できませんでした'));
        this.app.api.collabStop();
        break;
      }
      case 'op': {
        const o = opFrom(msg);
        if (!this.client || !o || !Number.isInteger(msg.rev) || !Number.isInteger(msg.author)) return;
        if (msg.author === this.myID) {
          const next = this.client.acknowledged(msg.rev);
          if (next) this.sendOp(next.op, next.baseRevision);
        } else {
          this.applyRemote(this.client.remote(o, msg.rev));
        }
        break;
      }
      case 'cursor':
        if (!Number.isInteger(msg.author) || !Number.isInteger(msg.loc) || !Number.isInteger(msg.len) || msg.author === this.myID) return;
        this.cursors.set(msg.author, { loc: msg.loc, len: msg.len });
        this.renderCursors();
        break;
      case 'chat':
        if (Number.isInteger(msg.author) && typeof msg.text === 'string') this.chat(this.users.get(msg.author), msg.text.slice(0, 2000));
        break;
      case 'join':
        if (!Number.isInteger(msg.id) || typeof msg.name !== 'string') return;
        this.users.set(msg.id, { id: msg.id, name: msg.name });
        this.system(t('{name} さんが参加しました', { name: msg.name }));
        this.changed();
        break;
      case 'leave': {
        if (!Number.isInteger(msg.id)) return;
        const name = (this.users.get(msg.id) || {}).name || t('だれか');
        this.users.delete(msg.id);
        this.cursors.delete(msg.id);
        this.system(t('{name} さんが抜けました', { name }));
        this.changed();
        break;
      }
      case 'bye':
        this.app.api.collabStop();
        this.closed(0, { decryptedAny: true });
        break;
      default:
        break;
    }
  }

  sendOp(o, base) { this.send({ t: 'op', rev: base, loc: o.loc, len: o.len, text: o.text }); }

  // ---------- 文書との結び付け ----------

  attach(tab) {
    this.tab = tab;
    tab.collab = this;
    this.changed();
    this.sendMyCursor();
  }

  /// 自分の編集を捕まえて送る (エディタの変更のたびに呼ばれる)
  localUpdate(update) {
    if (!this.active || !update.docChanged) return;
    for (const tr of update.transactions) {
      if (!tr.docChanged || tr.annotation(remoteAnnotation)) continue;
      const ops = [];
      // 前から順に、1 つずつ反映したときの位置にする (fromB は前の変更をふまえた位置)
      tr.changes.iterChanges((fromA, toA, fromB, toB, inserted) => ops.push(ot.op(fromB, toA - fromA, inserted.toString())));
      for (const o of ops) {
        this.shiftCursors(o);
        if (this.role === 'host') {
          const rev = this.server.localEdit(o);
          this.broadcast({ t: 'op', rev, author: 0, loc: o.loc, len: o.len, text: o.text });
        } else if (this.client) {
          const s = this.client.localEdit(o);
          if (s) this.sendOp(s.op, s.baseRevision);
        }
      }
    }
    this.renderCursors();
  }

  applyRemote(o) {
    if (ot.isNoop(o) || !this.tab) return;
    this.tab.editor.applyRemoteOp(o);
    this.shiftCursors(o);
    this.renderCursors();
    this.app.updateTabs();
  }

  /// 変更に合わせてほかの人のカーソル位置もずらす
  shiftCursors(o) {
    for (const [id, c] of this.cursors) {
      const s = ot.transformPosition(o, c.loc), e = ot.transformPosition(o, c.loc + c.len);
      this.cursors.set(id, { loc: s, len: Math.max(0, e - s) });
    }
  }

  renderCursors() {
    if (!this.tab || !this.app.tabs.includes(this.tab)) return;
    const list = [];
    for (const [id, c] of this.cursors) {
      if (id === this.myID || !this.users.has(id)) continue;
      list.push({ loc: c.loc, len: c.len, name: this.users.get(id).name, color: colorOf(id) });
    }
    this.tab.editor.setRemoteCursors(list);
  }

  /// 自分のカーソルが動いた (少しまとめて送る)
  localSelectionChanged() {
    if (!this.active) return;
    clearTimeout(this.cursorTimer);
    this.cursorTimer = setTimeout(() => this.sendMyCursor(), 50);
  }

  sendMyCursor() {
    if (!this.active || !this.tab) return;
    const sel = this.tab.editor.view.state.selection.main;
    const msg = { t: 'cursor', author: this.myID, loc: sel.from, len: sel.to - sel.from };
    if (this.role === 'host') this.broadcast(msg);
    else if (this.client) this.send(msg);
  }

  // ---------- チャット ----------

  sendChat(text) {
    const s = String(text).trim();
    if (!s) return;
    this.chat(this.users.get(this.myID) || { id: this.myID, name: this.myName }, s);
    if (!this.active) return;
    const msg = { t: 'chat', author: this.myID, text: s.slice(0, 2000) };
    if (this.role === 'host') this.broadcast(msg); else this.send(msg);
  }

  chat(user, text) { this.app.collabPanel.add(user ? { name: user.name, color: colorOf(user.id), mine: user.id === this.myID } : null, text); }
  system(text) { this.app.collabPanel.add(null, text); }
  changed() {
    // 1 行目の人の名前札が切れないよう、共同編集のあいだは本文の上に余白を取る
    if (this.tab && this.tab.el) { this.tab.el.classList.toggle('collab-active', this.active); this.tab.editor.remeasure(); }
    this.renderCursors(); this.app.collabPanel.render();
    this.app.pushMenuState();
    this.app.updateStatus();
  }

  // ---------- 終了 ----------

  stop() {
    if (!this.active) return;
    if (this.role === 'host') {
      this.broadcast({ t: 'bye' });
    } else {
      this.send({ t: 'bye' });
    }
    this.active = false;
    setTimeout(() => this.app.api.collabStop(), 300);
    for (const id of Array.from(this.users.keys())) if (id !== this.myID) this.users.delete(id);
    this.cursors.clear();
    this.system(this.role === 'host' ? t('共有を終了しました。') : t('共有から抜けました。'));
    this.changed();
  }

  /// 参加の取りやめ (承認待ちの途中)
  cancelJoin() {
    this.active = false;
    this.onJoinFailed = null;
    this.onWelcome = null;
    this.app.api.collabStop();
  }

  userList() {
    return Array.from(this.users.values()).sort((a, b) => a.id - b.id).map(u => ({ name: u.name, color: colorOf(u.id), me: u.id === this.myID, host: u.id === 0 }));
  }
}

function opFrom(msg) {
  if (!Number.isInteger(msg.loc) || !Number.isInteger(msg.len) || typeof msg.text !== 'string' || msg.loc < 0 || msg.len < 0) return null;
  return ot.op(msg.loc, msg.len, msg.text);
}

/// 右の欄: 参加している人の一覧とチャット
export class CollabPanel {
  constructor(app) {
    this.app = app;
    const pane = app.el.chatPane;
    this.status = h('div', { class: 'dim collab-status' });
    this.users = h('div', { class: 'collab-users' });
    this.log = h('div', { class: 'ai-log collab-log', role: 'log', 'aria-label': t('チャット') });
    this.input = h('textarea', { class: 'ai-input', rows: '1', placeholder: t('メッセージを書く'), 'aria-label': t('メッセージを書く') });
    const sendButton = h('button', { class: 'ai-send', title: t('送信 (Enter)'), 'aria-label': t('送信'), onclick: () => this.send() }, '↑');
    pane.append(
      h('div', { class: 'ai-head' }, h('strong', {}, t('共同編集')), h('span', { class: 'tb-space' }),
        h('button', { class: 'icon-button', title: t('閉じる'), 'aria-label': t('閉じる'), onclick: () => app.setPref('collabChatVisible', false) }, '✕')),
      this.status, this.users, this.log,
      h('div', { class: 'ai-composer' }, this.input, sendButton));
    this.input.addEventListener('keydown', e => {
      if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && e.keyCode !== 229) { e.preventDefault(); this.send(); }
    });
    this.input.addEventListener('input', () => { this.input.style.height = 'auto'; this.input.style.height = Math.min(120, this.input.scrollHeight) + 'px'; });
    this.render();
  }

  setVisible(on) {
    const pane = this.app.el.chatPane;
    if (pane.hidden !== !on) { pane.hidden = !on; this.app.scheduleRuler(); }
  }

  send() {
    const s = this.app.collab;
    if (!s || !this.input.value.trim()) return;
    s.sendChat(this.input.value);
    this.input.value = '';
    this.input.style.height = 'auto';
  }

  add(user, text) {
    const at = new Date().toTimeString().slice(0, 5);
    if (!user) this.log.append(h('div', { class: 'collab-system dim' }, `${at}  ${text}`));
    else {
      this.log.append(h('div', { class: 'ai-msg ' + (user.mine ? 'user' : 'ai') + ' collab-msg' },
        h('div', { class: 'collab-name' }, h('span', { class: 'collab-dot', style: { background: user.color } }), user.name, h('span', { class: 'ai-meta' }, at)),
        h('div', { class: 'ai-text' }, text)));
    }
    this.log.scrollTop = this.log.scrollHeight;
    // 欄を閉じていたら、メッセージが来たことを知らせる
    if (user && !user.mine && this.app.el.chatPane.hidden) toast(`${user.name}: ${text.slice(0, 60)}`);
  }

  render() {
    const s = this.app.collab;
    this.users.textContent = '';
    if (!s) { this.status.textContent = t('共有していません。「共有」メニューから始めます。'); return; }
    this.status.textContent = !s.active ? t('共有は終わっています。')
      : s.role === 'host' ? t('共有中 ({n} 人) ・ コード {code}', { n: s.users.size, code: s.code || '' })
        : t('参加中 ({n} 人)', { n: s.users.size });
    for (const u of s.userList()) {
      this.users.append(h('div', { class: 'collab-user' }, h('span', { class: 'collab-dot', style: { background: u.color } }),
        u.name + (u.me ? ' ' + t('(自分)') : '') + (u.host ? ' ' + t('(ホスト)') : '')));
    }
  }
}

// ---------- 共有を始める・参加する ----------

export async function startHosting(app) {
  const tab = app.active;
  if (app.collab && app.collab.active) { await alertBox(t('すでに共有中です'), t('先に「共有を終了 / 抜ける」を選んでください。')); return; }
  if (tab.paperMode !== 0) app.setPaperMode(tab, 0); // 共同編集は通常の表示で行う
  const name = app.prefs.collabName || app.init.hostName || 'PC';
  const port = h('input', { type: 'number', min: '1024', max: '65535', value: app.prefs.collabPort || 7650, style: { width: '90px' } });
  const nameInput = h('input', { type: 'text', class: 'wide', value: name });
  const ok = await modal({
    title: t('この文書を共有する'), width: 460,
    body: h('div', {},
      h('div', { class: 'dim' }, t('「{name}」を共有します。参加の申し込みが来たら、1 人ずつ承認します。', { name: tab.name })),
      h('div', { class: 'form-row top-gap' }, h('label', {}, t('自分の名前')), nameInput),
      h('div', { class: 'form-row' }, h('label', {}, t('ポート')), port),
      h('div', { class: 'dim' }, t('初めてのときは、Windows のファイアウォールの確認が出ます。同じネットワークの人とだけ使うなら「プライベート ネットワーク」にチェックして「アクセスを許可する」を押してください。'))),
    buttons: [{ label: t('共有を始める'), value: true, primary: true }, { label: t('キャンセル'), value: false, cancel: true }],
  });
  if (!ok) return;
  app.setPref('collabName', nameInput.value.trim() || name);
  app.setPref('collabPort', parseInt(port.value, 10) || 7650);
  const r = await app.api.collabHost(parseInt(port.value, 10) || 7650);
  if (r.status !== 'ok') { await alertBox(t('共有を始められませんでした'), r.message); return; }
  const s = new CollabSession(app, 'host', app.prefs.collabName);
  s.code = r.code;
  app.collab = s;
  s.attach(tab);
  app.setPref('collabChatVisible', true);
  s.system(t('共有を始めました。'));
  const where = r.addresses.length ? r.addresses.map(a => `${a}:${r.port}`) : [`(${t('アドレスが見つかりません')}):${r.port}`];
  await modal({
    title: t('共有を始めました'), width: 460,
    body: h('div', {},
      h('div', {}, t('相手に、次の「アドレス」と「共有コード」を伝えてください。')),
      h('div', { class: 'collab-share' },
        h('div', { class: 'dim' }, t('アドレス')),
        ...where.map(w => h('div', { class: 'form-row' }, h('code', { class: 'collab-code' }, w), h('button', { onclick: () => { app.api.copyText(w); toast(t('コピーしました')); } }, t('コピー')))),
        h('div', { class: 'dim top-gap' }, t('共有コード')),
        h('div', { class: 'form-row' }, h('code', { class: 'collab-code big' }, r.code), h('button', { onclick: () => { app.api.copyText(r.code); toast(t('コピーしました')); } }, t('コピー')))),
      h('div', { class: 'dim top-gap' }, t('共有コードは共有のたびに変わります。コードを知らない人は、承認の確認まで進めません。'))),
    buttons: [{ label: 'OK', value: true, primary: true, cancel: true }],
  });
}

export async function joinShare(app) {
  if (app.collab && app.collab.active) { await alertBox(t('すでに共有中です'), t('先に「共有を終了 / 抜ける」を選んでください。')); return; }
  const address = h('input', { type: 'text', class: 'wide', placeholder: '192.168.1.10:7650', autofocus: true });
  const code = h('input', { type: 'text', class: 'wide', placeholder: 'ABCD-EFGH-JKLM-NPQR', autocomplete: 'off', spellcheck: 'false' });
  const name = h('input', { type: 'text', class: 'wide', value: app.prefs.collabName || app.init.hostName || 'PC' });
  const error = h('div', { class: 'find-status warn' });
  const ok = await modal({
    title: t('共有に参加'), width: 460,
    body: h('div', {},
      h('div', { class: 'form-row' }, h('label', {}, t('アドレス')), address),
      h('div', { class: 'form-row' }, h('label', {}, t('共有コード')), code),
      h('div', { class: 'form-row' }, h('label', {}, t('自分の名前')), name),
      h('div', { class: 'dim' }, t('相手から聞いた「アドレス:ポート」と共有コードを入れます。Mac 版のさとるエディタにも参加できます。')),
      error),
    buttons: [{ label: t('参加する'), value: true, primary: true, validate: () => {
      if (!/^[^\s:]+(:\d{1,5})?$/.test(address.value.trim())) { error.textContent = t('アドレスは「192.168.1.10:7650」の形で入れてください。'); return false; }
      if (code.value.replace(/[^A-Za-z0-9]/g, '').length < 16) { error.textContent = t('共有コードは 16 文字です。'); return false; }
      return true;
    } }, { label: t('キャンセル'), value: false, cancel: true }],
  });
  if (!ok) return;
  const [host, portText] = address.value.trim().split(':');
  const myName = name.value.trim() || 'PC';
  app.setPref('collabName', myName);
  const s = new CollabSession(app, 'guest', myName);
  app.collab = s;
  let waiting = null;
  const result = new Promise(resolve => {
    s.onWelcome = (text, title) => resolve({ text, title });
    s.onJoinFailed = message => resolve({ error: message });
  });
  app.api.collabJoin(host, parseInt(portText, 10) || 7650, code.value);
  const waitDialog = modal({
    title: t('参加を申し込みました'), body: t('相手が承認するのを待っています…'),
    buttons: [{ label: t('やめる'), value: 'cancel', cancel: true }],
    onOpen: api => { waiting = api; },
  });
  const outcome = await Promise.race([result, waitDialog.then(v => ({ cancelled: v === 'cancel' || v === undefined }))]);
  if (waiting) waiting.close('done');
  if (outcome.cancelled) { s.cancelJoin(); app.collab = null; app.collabPanel.render(); return; }
  if (outcome.error) { app.collab = null; app.collabPanel.render(); await alertBox(t('参加できませんでした'), outcome.error); return; }
  const tab = app.newTab({ text: outcome.text });
  tab.name = t('(共有) {title}', { title: outcome.title || t('(無題)') });
  app.untitled -= 1;
  tab.plainChoice = true;
  app.resolveProfile(tab);
  if (!tab.profile && outcome.title) {
    tab.languageOverride = '';
    const guess = app.profiles.find(p => p.extensions.some(e => outcome.title.toLowerCase().endsWith('.' + e)));
    if (guess) { tab.languageOverride = guess.name; tab.profile = guess; }
  }
  tab.editor.configure(app.prefs, tab.profile);
  s.attach(tab);
  app.setPref('collabChatVisible', true);
  s.system(t('参加しました。'));
  app.updateTabs();
}
