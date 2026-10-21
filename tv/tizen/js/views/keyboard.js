import { t } from '../i18n.js';
import { el, button, row } from '../ui.js';
export const keyboardLetters = ['1234567890ß', 'qwertzuiopü', 'asdfghjklöä', 'yxcvbnm.-_@'];
export const keyboardSymbols = ['!', '?', '#', '+', '=', '*', ',', ';', ':', '/', '\\', '"', "'", '(', ')', '[', ']', '{', '}', '<', '>', '|', '~', '^', '`', '$', '%', '&'];
export const keyboardControls = [0, 2, 4, 8, 10];
function keyboardColumn(column) {
  return keyboardControls.filter(start => start <= column).pop();
}
// Coordinates are zero-based. null means leave the keyboard through its top/bottom edge.
export function keyboardMove(position, direction, symbols) {
  let r = position.row;
  let c = r === 4 ? keyboardColumn(position.column) : position.column;
  const count = rowIndex => rowIndex === 4 ? 11 : symbols ? Math.max(0, Math.min(11, keyboardSymbols.length - rowIndex * 11)) : 11;
  if (direction === 'left' || direction === 'right') {
    const choices = r === 4 ? keyboardControls : Array.from({ length: count(r) }, (_, i) => i);
    const index = choices.indexOf(c);
    c = choices[(index + (direction === 'left' ? -1 : 1) + choices.length) % choices.length];
  } else {
    const delta = direction === 'up' ? -1 : 1;
    do { r += delta; } while (r >= 0 && r <= 4 && !count(r));
    if (r < 0 || r > 4) return null;
    c = r === 4 ? keyboardColumn(c) : Math.min(c, count(r) - 1);
  }
  return { row: r, column: c };
}
export function activateShift(mode, lastActivation, now) {
  if (mode === 'caps') return 'off';
  if (mode === 'once' && now - lastActivation <= 400) return 'caps';
  return mode === 'once' ? 'off' : 'once';
}
export function keyboard(onEdit) {
  const root = el('div', 'keyboard');
  let mode = 'off'; let lastShift = -Infinity; let symbols = false; let shiftTimer = null;
  const cells = [];
  let shift; let symbolKey;
  function labels() {
    cells.forEach((line, r) => line.forEach((key, c) => {
      const character = symbols ? keyboardSymbols[r * 11 + c] || '' : keyboardLetters[r][c];
      key.disabled = !character;
      key.textContent = mode === 'off' ? character : character.toUpperCase();
    }));
    shift.classList.toggle('shift-once', mode === 'once'); shift.classList.toggle('shift-caps', mode === 'caps');
    shift.setAttribute('aria-pressed', String(mode !== 'off'));
    shift.setAttribute('aria-label', t(mode === 'caps' ? 'capsLock' : 'shift'));
    symbolKey.classList.toggle('selected', symbols); symbolKey.setAttribute('aria-pressed', String(symbols));
  }
  function focusCell(position) {
    const key = root.querySelector('[data-key-row="' + position.row + '"][data-key-column="' + position.column + '"]');
    if (key) key.focus();
  }
  function coordinate(key, r, c, span) {
    key.dataset.keyRow = r; key.dataset.keyColumn = c;
    key.style.gridColumn = (c + 1) + ' / span ' + (span || 1);
    return key;
  }
  for (let r = 0; r < 4; r++) {
    const line = row('keyboard-' + r, 'keyboard-row'); cells[r] = [];
    for (let c = 0; c < 11; c++) {
      const key = button('', () => {
        const character = symbols ? keyboardSymbols[r * 11 + c] : keyboardLetters[r][c];
        if (!character) return;
        onEdit('add', mode === 'off' ? character : character.toUpperCase());
        if (mode === 'once' && character.toLowerCase() !== character.toUpperCase()) { mode = 'off'; labels(); }
      }, 'key-' + keyboardLetters[r][c], 'key');
      line.appendChild(coordinate(key, r, c)); cells[r].push(key);
    }
    root.appendChild(line);
  }
  const controls = row('keyboard-controls', 'keyboard-row');
  shift = button(t('shift'), () => {
    const now = Date.now(); mode = activateShift(mode, lastShift, now); lastShift = now; labels();
  }, 'key-case', 'key wide');
  symbolKey = button(t('symbols'), () => { symbols = !symbols; labels(); }, 'key-symbols', 'key wide');
  const controlKeys = [shift, symbolKey,
    button(t('space'), () => onEdit('add', ' '), 'key-space', 'key wide'),
    button('⌫', () => onEdit('delete'), 'key-delete', 'key wide'),
    button(t('clear'), () => onEdit('clear'), 'key-clear', 'key wide')];
  controlKeys[3].setAttribute('aria-label', t('delete'));
  controlKeys.forEach((key, i) => controls.appendChild(coordinate(key, 4, keyboardControls[i], (keyboardControls[i + 1] || 11) - keyboardControls[i])));
  root.appendChild(controls); labels();
  const cancelHold = () => { clearTimeout(shiftTimer); shiftTimer = null; };
  shift.addEventListener('blur', cancelHold);
  shift.addEventListener('keyup', event => { if (event.keyCode === 13) { event.preventDefault(); cancelHold(); } });
  root.addEventListener('keydown', event => {
    const key = event.target.closest('[data-key-row]');
    if (!key) return;
    const direction = ['left', 'up', 'right', 'down'][event.keyCode - 37];
    if (direction) {
      const next = keyboardMove({ row: Number(key.dataset.keyRow), column: Number(key.dataset.keyColumn) }, direction, symbols);
      if (next) { event.preventDefault(); event.stopPropagation(); focusCell(next); }
    } else if (event.keyCode === 13 && key === shift) {
      if (event.repeat) {
        event.preventDefault(); event.stopPropagation();
        if (mode === 'once') { mode = 'caps'; labels(); }
      } else {
        cancelHold();
        shiftTimer = setTimeout(() => {
          if (root.isConnected && document.activeElement === shift && mode === 'once') { mode = 'caps'; labels(); }
        }, 400);
      }
    }
  });
  return root;
}
export function editText(value, action, text) {
  if (action === 'clear') return '';
  if (action === 'delete') return value.slice(0, -1);
  return (value + text).slice(0, 500);
}
