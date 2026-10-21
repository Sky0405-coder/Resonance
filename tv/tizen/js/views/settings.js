import { t } from '../i18n.js';
import { el, button, heading, row } from '../ui.js';
export function settingsView(ctx) {
  const root = el('div', 'settings-page'); root.appendChild(heading(t('settings')));
  root.appendChild(el('p', 'muted', t('connected') + ' ' + ctx.api.server));
  const options = row('settings-display', 'settings-display');
  const visualizer = button('', () => {
    ctx.preferences.set('visualizer', !ctx.preferences.value.visualizer); refresh();
  }, 'settings-visualizer');
  const background = button('', () => {
    ctx.preferences.set('background', ctx.preferences.value.background === 'dark' ? 'dynamic' : 'dark'); refresh();
  }, 'settings-background');
  function refresh() {
    visualizer.textContent = t('showVisualizer') + ': ' + t(ctx.preferences.value.visualizer ? 'on' : 'off');
    visualizer.setAttribute('aria-pressed', String(ctx.preferences.value.visualizer));
    background.textContent = t('background') + ': ' + t(ctx.preferences.value.background === 'dark' ? 'dark' : 'dynamic');
  }
  refresh(); options.appendChild(visualizer); options.appendChild(background); root.appendChild(options);
  const label = el('label', 'field', t('server'));
  const input = el('input'); input.value = ctx.api.server; input.readOnly = typeof tizen !== 'undefined';
  input.dataset.focusable = ''; input.dataset.focusId = 'settings-server';
  input.addEventListener('click', () => ctx.app.textKeyboard(input, true)); label.appendChild(input); root.appendChild(label);
  root.appendChild(el('p', 'muted', t('serverHint')));
  const error = el('p', 'form-error'); error.setAttribute('role', 'alert');
  const actions = row('settings-actions');
  actions.appendChild(button(t('save'), async () => {
    try { await ctx.app.changeServer(input.value); } catch (failure) { error.textContent = failure.message; }
  }, 'settings-save', 'button primary'));
  actions.appendChild(button(t('logout'), () => ctx.app.logout(), 'settings-logout'));
  root.appendChild(actions); root.appendChild(error);
  root.appendChild(el('p', 'settings-help muted', t('remoteHint') + '\n' + t('colorHint')));
  return { node: root };
}
