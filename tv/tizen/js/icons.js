// Material-style 24px paths, shared by both player sizes. No font glyph dependency on Tizen.
const iconPaths = {
  shuffle: 'M10.59 9.17 5.41 4 4 5.41l5.17 5.17 1.42-1.41zM14.5 4l2.04 2.04L4 18.59 5.41 20 17.96 7.46 20 9.5V4h-5.5zm.33 9.41-1.41 1.41 3.13 3.13L14.5 20H20v-5.5l-2.04 2.04-3.13-3.13z',
  skip_previous: 'M6 6h2v12H6zm3.5 6L18 18V6z',
  play_arrow: 'M8 5v14l11-7z',
  pause: 'M6 5h4v14H6zm8 0h4v14h-4z',
  skip_next: 'm6 18 8.5-6L6 6zm10-12h2v12h-2z',
  repeat: 'm7 7 10 0v3l4-4-4-4v3H5v6h2zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2z',
  repeat_one: 'm7 7 10 0v3l4-4-4-4v3H5v6h2zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2zM13 15V9h-1l-2 1v1h1.5v4z',
  lyrics: 'M4 3h16a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H7l-4 3V4a1 1 0 0 1 1-1zm2 4v2h8V7zm0 4v2h8v-2zm0 4v2h5v-2zm12-10v6.2a2 2 0 1 0 1 1.8V7h1V5z',
  favorite: 'M12 21.35 10.55 20.03C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54z',
  favorite_border: 'M16.5 3c-1.74 0-3.41.81-4.5 2.09C10.91 3.81 9.24 3 7.5 3 4.42 3 2 5.42 2 8.5c0 3.78 3.4 6.86 8.55 11.54L12 21.35l1.45-1.32C18.6 15.36 22 12.28 22 8.5 22 5.42 19.58 3 16.5 3zM12.1 18.55l-.1.1-.1-.1C7.14 14.24 4 11.39 4 8.5 4 6.5 5.5 5 7.5 5c1.54 0 3.04.99 3.57 2.36h1.87C13.46 5.99 14.96 5 16.5 5 18.5 5 20 6.5 20 8.5c0 2.89-3.14 5.74-7.9 10.05z'
};
export function svgIcon(name) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('aria-hidden', 'true'); svg.setAttribute('focusable', 'false');
  const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  path.setAttribute('d', iconPaths[name] || iconPaths.play_arrow); svg.appendChild(path);
  return svg;
}
export function setIcon(node, name) {
  if (node.dataset.icon === name) return;
  node.textContent = ''; node.appendChild(svgIcon(name)); node.dataset.icon = name;
}
