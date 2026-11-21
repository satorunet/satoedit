import { t } from '../../shared/i18n';
// 画面の部品: 要素を作る小道具、確認のダイアログ、動かせる小窓、ポップアップメニュー

/// h('div', { class: 'x', onclick: fn }, 子…) のように要素を作る
export function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'style' && typeof v === 'object') Object.assign(el.style, v);
    else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
    else if (k === 'value' || k === 'checked' || k === 'disabled' || k === 'selected') el[k] = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const c of children.flat(Infinity)) {
    if (c === null || c === undefined || c === false) continue;
    el.append(c.nodeType ? c : document.createTextNode(String(c)));
  }
  return el;
}

const layer = () => document.getElementById('overlays');
let openModals = 0;
export function isModalOpen() { return openModals > 0; }

/// ダイアログを出す。buttons: [{ label, value, primary, cancel, validate }]。閉じたときの value を返す
/// validate が false (または Promise<false>) を返したら閉じない
export function modal({ title, body, buttons, width, onOpen, className, noEnter }) {
  closePopup(); // 右クリックのメニューが残っていれば閉じる (ダイアログの上に重ならないように)
  return new Promise(resolve => {
    const previous = document.activeElement;
    const backdrop = h('div', { class: 'modal-backdrop' });
    const content = h('div', { class: 'modal-body' });
    if (typeof body === 'string') content.append(...body.split('\n').map(line => h('div', { class: 'modal-line' }, line || ' ')));
    else if (body) content.append(body);
    const buttonRow = h('div', { class: 'modal-buttons' });
    const box = h('div', { class: 'modal ' + (className || ''), role: 'dialog', 'aria-modal': 'true', style: { width: (width || 440) + 'px' } },
      h('div', { class: 'modal-title' }, title || ''), content, buttonRow);
    let closed = false;
    const close = value => {
      if (closed) return;
      closed = true;
      openModals -= 1;
      backdrop.remove();
      document.removeEventListener('keydown', onKey, true);
      if (previous && previous.focus && document.contains(previous)) previous.focus();
      resolve(value);
    };
    const press = async b => {
      if (b.validate) {
        buttonRow.querySelectorAll('button').forEach(x => { x.disabled = true; });
        let ok = false;
        try { ok = await b.validate(); } catch (e) { ok = false; }
        buttonRow.querySelectorAll('button').forEach(x => { x.disabled = false; });
        if (ok === false) return;
      }
      close(b.value);
    };
    const list = buttons || [{ label: 'OK', value: true, primary: true }];
    for (const b of list) {
      buttonRow.append(h('button', { class: b.primary ? 'primary' : '', onclick: () => press(b) }, b.label));
    }
    const onKey = e => {
      if (!backdrop.contains(document.activeElement) && document.activeElement !== document.body) return;
      if (e.isComposing) return;
      if (e.key === 'Escape') {
        const c = list.find(b => b.cancel) || (list.length === 1 ? list[0] : null);
        if (c) { e.preventDefault(); e.stopPropagation(); close(c.value); }
      } else if (e.key === 'Enter' && !noEnter && !(e.target instanceof HTMLTextAreaElement) && !(e.target instanceof HTMLButtonElement)) {
        const p = list.find(b => b.primary);
        if (p) { e.preventDefault(); e.stopPropagation(); press(p); }
      }
    };
    document.addEventListener('keydown', onKey, true);
    backdrop.append(box);
    layer().append(backdrop);
    openModals += 1;
    const api = { close, box, content };
    if (onOpen) onOpen(api);
    const focusTarget = box.querySelector('[autofocus]') || box.querySelector('input, select, textarea') || buttonRow.querySelector('button.primary') || buttonRow.querySelector('button');
    if (focusTarget) { focusTarget.focus(); if (focusTarget.select && focusTarget.type !== 'checkbox' && focusTarget.type !== 'radio') focusTarget.select(); }
  });
}

export function alertBox(title, message) {
  return modal({ title, body: message || '', buttons: [{ label: 'OK', value: true, primary: true, cancel: true }] });
}

export function confirmBox(title, message, okLabel = 'OK', cancelLabel = '') {
  return modal({ title, body: message || '', buttons: [{ label: okLabel, value: true, primary: true }, { label: cancelLabel || t('キャンセル'), value: false, cancel: true }] });
}

/// 1 行の入力。キャンセルなら null
export async function promptBox(title, message, initial = '', { type = 'text', placeholder = '' } = {}) {
  const input = h('input', { type, value: initial, placeholder, class: 'wide', autofocus: true });
  const ok = await modal({
    title, body: h('div', {}, message ? h('div', { class: 'modal-line' }, message) : null, input),
    buttons: [{ label: 'OK', value: true, primary: true }, { label: t('キャンセル'), value: false, cancel: true }],
  });
  return ok ? input.value : null;
}

/// 文書の上に浮かぶ、動かせる小窓 (検索の窓など)。同じ id のものは 1 つだけ
const floats = new Map();
export function floatWindow({ id, title, body, width, onClose }) {
  if (floats.has(id)) floats.get(id).close();
  const bar = h('div', { class: 'float-title' }, h('span', {}, title), h('button', { class: 'float-close', title: t('閉じる (Esc)'), onclick: () => api.close() }, '✕'));
  const box = h('div', { class: 'float-window', style: { width: (width || 420) + 'px' } }, bar, h('div', { class: 'float-body' }, body));
  const api = {
    box,
    close() {
      if (!floats.has(id)) return;
      floats.delete(id);
      box.remove();
      if (onClose) onClose();
    },
    setTitle(t) { bar.firstChild.textContent = t; },
  };
  let drag = null;
  bar.addEventListener('mousedown', e => {
    if (e.target.closest('button')) return;
    const r = box.getBoundingClientRect();
    drag = { dx: e.clientX - r.left, dy: e.clientY - r.top };
    e.preventDefault();
  });
  window.addEventListener('mousemove', e => {
    if (!drag) return;
    const x = Math.max(0, Math.min(window.innerWidth - 80, e.clientX - drag.dx));
    const y = Math.max(0, Math.min(window.innerHeight - 40, e.clientY - drag.dy));
    box.style.left = x + 'px';
    box.style.top = y + 'px';
    box.style.right = 'auto';
  });
  window.addEventListener('mouseup', () => { drag = null; });
  box.addEventListener('keydown', e => {
    if (e.key === 'Escape' && !e.isComposing) { e.preventDefault(); e.stopPropagation(); api.close(); }
  });
  layer().append(box);
  floats.set(id, api);
  return api;
}
export function floatOpen(id) { return floats.get(id) || null; }

/// ポップアップメニュー。items: [{ label, checked, disabled, header, icon, submenu: [...], action } | 'sep']。x, y は画面上の位置
/// header は押せない見出し (薄い字)。submenu を付けると、乗せたとき横に出る
let popups = [];
function buildPopup(items, x, y, { alignBottom, level = 0, beside = null, className = '' } = {}) {
  const menu = h('div', { class: 'popup-menu' + (className ? ' ' + className : ''), role: 'menu' });
  for (const it of items) {
    if (it === 'sep') { menu.append(h('div', { class: 'popup-sep' })); continue; }
    const row = h('div', {
      class: 'popup-item' + (it.disabled || it.header ? ' disabled' : '') + (it.header ? ' header' : '') + (it.submenu ? ' has-sub' : ''), role: 'menuitem',
      title: it.tip || null,
      onclick: e => {
        if (it.submenu) { openSub(); e.stopPropagation(); return; }
        if (it.disabled || it.header) return;
        closePopup();
        it.action && it.action();
      },
      onmouseenter: () => {
        // 乗せた行の子メニューを出す (ほかの子メニューは閉じる)
        while (popups.length > level + 1) popups.pop().remove();
        if (it.submenu && !it.disabled) openSub();
      },
    }, h('span', { class: 'popup-check' }, it.checked ? '✓' : (it.icon || '')), h('span', { class: 'popup-label' }, it.label), it.submenu ? h('span', { class: 'popup-arrow' }, '›') : null);
    const openSub = () => {
      while (popups.length > level + 1) popups.pop().remove();
      const r = row.getBoundingClientRect();
      buildPopup(it.submenu, r.right - 2, r.top - 4, { level: level + 1, beside: r });
    };
    menu.append(row);
  }
  layer().append(menu);
  const r = menu.getBoundingClientRect();
  let left = Math.min(x, window.innerWidth - r.width - 4);
  if (beside && x + r.width > window.innerWidth - 4) left = Math.max(4, beside.left - r.width + 2);
  let top = alignBottom ? y - r.height : y;
  if (top + r.height > window.innerHeight - 4) top = Math.max(4, window.innerHeight - r.height - 4);
  if (top < 4) top = 4;
  menu.style.left = Math.max(4, left) + 'px';
  menu.style.top = top + 'px';
  popups.push(menu);
  return menu;
}
export function popupMenu(items, x, y, opts = {}) {
  closePopup();
  buildPopup(items, x, y, opts);
  setTimeout(() => {
    document.addEventListener('mousedown', outside, true);
    document.addEventListener('keydown', escape, true);
  }, 0);
}
function outside(e) { if (popups.length && !popups.some(m => m.contains(e.target))) closePopup(); }
function escape(e) { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closePopup(); } }
export function isPopupOpen() { return popups.length > 0; }
export function closePopup() {
  if (!popups.length) return;
  for (const m of popups) m.remove();
  popups = [];
  document.removeEventListener('mousedown', outside, true);
  document.removeEventListener('keydown', escape, true);
}

/// 画面の下に少しのあいだ出る知らせ
let toastTimer = null;
export function toast(message) {
  let el = document.getElementById('toast');
  if (!el) { el = h('div', { id: 'toast' }); layer().append(el); }
  el.textContent = message;
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('show'), 2600);
}
