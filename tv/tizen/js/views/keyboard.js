import { t } from '../i18n.js';
import { el, button, row } from '../ui.js';
export function keyboard(onEdit, extended) {
  const root = el('div', 'keyboard');
  let lower = false;
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'.split('').concat(['ä', 'ö', 'ü', 'ß']);
  if (extended) chars.push('.', ':', '/', '-', '_', '@', '!', '?', '#', '+', '=', '*', ',', ';', '$', '%', '&', '(', ')', '[', ']', '{', '}', '\\', '"', "'", '<', '>', '|', '~', '^', '`');
  const letters = [];
  for (let offset = 0; offset < chars.length; offset += 8) {
    const line = row('keyboard-' + offset, 'keyboard-row');
    chars.slice(offset, offset + 8).forEach(character => {
      const key = button(character, () => onEdit('add', lower ? character.toLowerCase() : character), 'key-' + character, 'key');
      letters.push({ key: key, character: character }); line.appendChild(key);
    });
    root.appendChild(line);
  }
  const controls = row('keyboard-controls', 'keyboard-row');
  controls.appendChild(button('a / A', () => {
    lower = !lower;
    letters.forEach(item => { item.key.textContent = lower ? item.character.toLowerCase() : item.character; });
  }, 'key-case', 'key wide'));
  controls.appendChild(button(t('space'), () => onEdit('add', ' '), 'key-space', 'key wide'));
  controls.appendChild(button('⌫ ' + t('delete'), () => onEdit('delete'), 'key-delete', 'key wide'));
  controls.appendChild(button(t('clear'), () => onEdit('clear'), 'key-clear', 'key wide'));
  root.appendChild(controls);
  return root;
}
export function editText(value, action, text) {
  if (action === 'clear') return '';
  if (action === 'delete') return value.slice(0, -1);
  return (value + text).slice(0, 500);
}
