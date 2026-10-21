import { t } from '../i18n.js';
import { el, button, heading, row, image } from '../ui.js';
export function loginView(ctx) {
  const root = el('section', 'login-page');
  const brand = el('div', 'login-brand'); brand.appendChild(image('icon.png', 'login-logo'));
  brand.appendChild(el('div', 'eyebrow', 'RESONANCE · TV'));
  brand.appendChild(heading(t('welcome'), t('loginHint'))); root.appendChild(brand);
  const form = el('form', 'login-form');
  const inputs = {};
  ['server', 'username', 'password'].forEach(name => {
    const label = el('label', 'field', t(name));
    const input = el('input'); input.name = name; input.autocomplete = 'off';
    input.type = name === 'password' ? 'password' : 'text';
    input.value = name === 'server' ? ctx.api.server : '';
    input.readOnly = typeof tizen !== 'undefined';
    input.dataset.focusable = ''; input.dataset.focusId = 'login-' + name;
    input.addEventListener('click', () => ctx.app.textKeyboard(input, true));
    label.appendChild(input); form.appendChild(label); inputs[name] = input;
  });
  const controls = row('login-controls');
  controls.appendChild(button(t('loginKeyboard'), () => ctx.app.textKeyboard(inputs.username, true), 'login-keyboard'));
  controls.appendChild(button(t('showPassword'), event => {
    inputs.password.type = inputs.password.type === 'password' ? 'text' : 'password';
    event.currentTarget.textContent = t(inputs.password.type === 'password' ? 'showPassword' : 'hidePassword');
  }, 'show-password'));
  form.appendChild(controls);
  const error = el('p', 'form-error'); error.setAttribute('role', 'alert'); form.appendChild(error);
  const submit = button(t('login'), signIn, 'login-submit', 'button primary'); form.appendChild(submit);
  let pending = false;
  async function signIn() {
    if (pending) return;
    if (!inputs.username.value.trim() || !inputs.password.value) { error.textContent = t('loginRequired'); return; }
    pending = true; submit.textContent = t('loading');
    try {
      await ctx.api.login(inputs.server.value, inputs.username.value.trim(), inputs.password.value);
      inputs.password.value = '';
      ctx.app.authenticated();
    } catch (failure) { if (ctx.active()) error.textContent = failure.message; }
    finally { pending = false; submit.textContent = t('login'); }
  }
  form.addEventListener('submit', event => { event.preventDefault(); signIn(); });
  root.appendChild(form);
  root.appendChild(el('p', 'login-foot muted', t('remoteHint')));
  return { node: root };
}
