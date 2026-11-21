// ツールバーの絵 (線画)。24 × 24 の枠に描いてある
const P = {
  new: 'M6 3h8l4 4v14H6zM14 3v4h4M12 11v6M9 14h6',
  open: 'M3 7h6l2 2h10v10H3zM3 11h18',
  save: 'M4 4h13l3 3v13H4zM8 4v5h7V4M8 20v-6h8v6',
  saveAs: 'M4 4h11l3 3v6M8 4v5h6V4M4 4v16h8M15 20l1-4 5-5 2 2-5 5z',
  undo: 'M9 7L4 12l5 5M4 12h10a5 5 0 0 1 0 10h-2',
  redo: 'M15 7l5 5-5 5M20 12H10a5 5 0 0 0 0 10h2',
  folder: 'M3 4h18v16H3zM9 4v16M5 8h2M5 11h2M5 14h2',
  cut: 'M6 6l12 12M18 6L6 18M6 19a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5zM18 19a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5z',
  copy: 'M8 8h12v13H8zM4 16V3h11',
  paste: 'M6 5h12v16H6zM9 3h6v4H9zM9 12h6M9 16h6',
  duplicate: 'M4 6h10v10H4zM10 10h10v10H10zM15 13v4M13 15h4',
  find: 'M10.5 17a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13zM15.5 15.5L21 21',
  replace: 'M4 8h14l-3-3M20 16H6l3 3',
  grep: 'M5 3h9l4 4v5M5 3v18h6M14 3v4h4M16 20a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM18.6 19.1L21 21.5',
  goto: 'M4 12h12M12 7l5 5-5 5M20 4v16',
  diff: 'M7 4v8M3 8h8M4 18h7M15 6l5 12M14 18h7',
  split: 'M3 4h18v16H3zM3 12h18',
  // 用紙切替: 紙と、回る矢印
  paper: 'M4 3h9l3 3v6M4 3v18h7M7 8h6M7 11h6M7 14h3M14 18a4 4 0 0 1 6.8-2.8M21 13v2.6h-2.6M21 18a4 4 0 0 1-6.8 2.8M14 23v-2.6h2.6',
  libraryGrid: 'M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z',
  library: 'M3 4h18v16H3zM9 4v16M12 8h6M12 12h6M12 16h4M5 8h2M5 12h2',
  publish: 'M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1',
  ai: 'M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8zM19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z',
  theme: 'M12 3a9 9 0 1 0 0 18c1.5 0 2-1 1.5-2.2-.6-1.5.3-2.8 2-2.8H18a3 3 0 0 0 3-3c0-5.5-4-10-9-10zM7.5 12.5h.01M9.5 8h.01M14.5 7.5h.01',
  lock: 'M6 11h12v10H6zM8 11V8a4 4 0 0 1 8 0v3',
  refresh: 'M20 12a8 8 0 1 1-2.3-5.7M20 4v5h-5',
  file: 'M6 3h8l4 4v14H6zM14 3v4h4',
  dir: 'M3 6h6l2 2h10v11H3z',
  chevron: 'M9 6l6 6-6 6',
  camera: 'M4 7h4l1.5-2h5L16 7h4v12H4zM12 16.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7z',
  server: 'M4 4h16v6H4zM4 14h16v6H4zM7 7h.01M7 17h.01M11 7h6M11 17h6',
  share: 'M9 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM3 20v-1a5 5 0 0 1 10 0v1M17 11a2.5 2.5 0 1 0 0-5M17 14a4 4 0 0 1 4 4v2',
  print: 'M7 8V3h10v5M5 8h14v9H5zM8 14h8v7H8z',
};

export function icon(name, size = 18) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('width', size);
  svg.setAttribute('height', size);
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '1.6');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  svg.setAttribute('aria-hidden', 'true');
  const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  path.setAttribute('d', P[name] || P.file);
  svg.append(path);
  return svg;
}
