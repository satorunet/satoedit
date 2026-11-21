'use strict';
// 名前 (拡張子) のない文書の中身から、言語の見当をつける (Mac 版の LanguageGuess と同じ)。
// 返すのはプロファイルの名前。分からなければ null
function guess(text) {
  const head = String(text || '').slice(0, 4000);
  const t = head.trim();
  if (!t) return null;
  const lower = t.toLowerCase();
  const has = re => new RegExp(re, 'm').test(head);
  if (t.startsWith('#!')) {
    const first = t.split('\n')[0];
    if (first.includes('python')) return 'Python';
    if (first.includes('node')) return 'JavaScript / TypeScript';
    if (first.includes('ruby')) return 'Ruby';
    if (first.includes('php')) return 'PHP';
    return 'シェル';
  }
  if (head.includes('<?php')) return 'PHP';
  if (lower.startsWith('<!doctype html') || lower.startsWith('<html') || has('^\\s*<(div|head|body|p|span|ul|section|table|form|script|style)[\\s>]')) return 'HTML / XML';
  if (t.startsWith('<?xml')) return 'HTML / XML';
  if ((t.startsWith('{') || t.startsWith('['))) { try { JSON.parse(t); return 'JSON'; } catch (_) { /* 違う */ } }
  if (has('^package\\s+main\\b') || (has('^func\\s+\\w+\\(.*\\)\\s*\\{') && has(':='))) return 'Go';
  if (has('^\\s*fn\\s+\\w+') && (has('\\blet\\s+mut\\b') || has('->') || has('println!'))) return 'Rust';
  if (has('^\\s*import\\s+(SwiftUI|UIKit|AppKit|Foundation)\\b') || (has('^\\s*func\\s+\\w+') && has('\\b(let|var)\\s+\\w+'))) return 'Swift';
  if (has('^\\s*#include\\s*[<"]') || has('\\bint\\s+main\\s*\\(')) return 'C / C++ / Objective-C';
  if (has('^\\s*(public\\s+)?(class|interface)\\s+\\w+') && has('\\b(public|private)\\s+(static\\s+)?\\w+\\s+\\w+\\s*\\(')) return 'Java / Kotlin';
  if (has('^\\s*def\\s+\\w+\\s*\\(.*\\)\\s*:') || (has('^\\s*(from\\s+\\S+\\s+)?import\\s+\\w+') && !has('[;{}]\\s*$')) || has('^\\s*class\\s+\\w+(\\(.*\\))?\\s*:')) return 'Python';
  if (has('^\\s*def\\s+\\w+') && has('^\\s*end\\s*$')) return 'Ruby';
  if (has('\\b(function\\s+\\w*\\s*\\(|const\\s+\\w+\\s*=|let\\s+\\w+\\s*=|=>|console\\.log|document\\.|addEventListener)')) return 'JavaScript / TypeScript';
  if (/^\s*(select\s+.+\s+from|insert\s+into|create\s+table|delete\s+from)\b/im.test(head)) return 'SQL';
  if (has('^[\\w.#\\-\\[\\]=:\\s,>*]+\\{\\s*$') && has('^\\s*[\\w-]+\\s*:\\s*[^;]+;\\s*$')) return 'CSS';
  if (has('^(echo|cd|export|if \\[|for \\w+ in)\\b')) return 'シェル';
  if (has('^#{1,6}\\s+\\S') || (has('^\\s*[-*]\\s+\\S') && has('\\[.+\\]\\(.+\\)'))) return 'Markdown';
  if (has('^[\\w-]+:\\s*\\S') && has('^\\s+-\\s+\\S') && !has('[;{}]')) return 'YAML';
  return null;
}
module.exports = { guess };
