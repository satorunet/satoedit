'use strict';
// 表示する言葉の切り替え (日本語 / 英語)。
// プログラムの中は日本語で書き、英語のときは en.js の対応表で置き換える。対応がなければ日本語のまま出す。
const en = require('./en');

const LANGUAGES = [
  { id: 'auto', label: '自動 (Windows の言語に合わせる)' },
  { id: 'ja', label: '日本語' },
  { id: 'en', label: 'English' },
];

let current = 'ja';

/// 設定の値 ('auto' | 'ja' | 'en') と OS の言語 ('ja-JP' など) から、実際に使う言語を決める
function resolve(setting, systemLocale) {
  if (setting === 'ja' || setting === 'en') return setting;
  return String(systemLocale || '').toLowerCase().startsWith('ja') ? 'ja' : 'en';
}

function setLanguage(lang) { current = lang === 'en' ? 'en' : 'ja'; }
function language() { return current; }

/// t('{n} 件見つかりました', { n: 3 })
function t(text, params) {
  let s = text;
  if (current === 'en' && typeof text === 'string' && Object.prototype.hasOwnProperty.call(en, text)) s = en[text];
  if (params && typeof s === 'string') s = s.replace(/\{(\w+)\}/g, (m, k) => (k in params ? String(params[k]) : m));
  return s;
}

module.exports = { LANGUAGES, resolve, setLanguage, language, t };
