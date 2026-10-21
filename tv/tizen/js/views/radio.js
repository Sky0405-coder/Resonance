import { t } from '../i18n.js';
import { el, button, heading, shelf, errorBox, releaseImages } from '../ui.js';
import { keyboard, editText } from './keyboard.js';
export async function radioView(ctx) {
  const root = el('div', 'radio-page'); root.appendChild(heading(t('radio'), t('radioHint')));
  const split = el('div', 'search-split'); const entry = el('div', 'search-entry');
  const input = el('input', 'search-input'); input.placeholder = t('radioHint'); input.setAttribute('aria-label', t('radioHint'));
  input.dataset.focusable = ''; input.dataset.focusId = 'radio-input'; input.readOnly = typeof tizen !== 'undefined';
  input.value = ctx.route.query || ''; entry.appendChild(input);
  const results = el('div', 'search-results');
  let timer = null; let version = 0; let disposed = false; let offset = 0;
  function schedule() { ctx.route.query = input.value; clearTimeout(timer); version++; timer = setTimeout(() => load(false), 400); }
  input.addEventListener('input', schedule);
  entry.appendChild(keyboard((action, text) => { input.value = editText(input.value, action, text); schedule(); }));
  split.appendChild(entry); split.appendChild(results); root.appendChild(split);
  async function load(append) {
    const current = ++version;
    const query = input.value.trim();
    if (!append) { offset = 0; releaseImages(results); results.textContent = t('loading'); }
    try {
      const requests = [ctx.api.request('/api/worldradio/stations', { query: { q: query, offset: offset, limit: 50 } })];
      if (!query && !append) requests.push(ctx.api.request('/api/worldradio/favorites'));
      // Each section stays usable if the directory or favorites request fails independently.
      const responses = await Promise.all(requests.map(request => request.then(value => ({ value: value }), error => ({ error: error }))));
      if (disposed || current !== version) return;
      if (!append) results.textContent = '';
      if (responses[1]) {
        if (responses[1].error) results.appendChild(errorBox(responses[1].error.message, () => load(false)));
        else if (responses[1].value.length) results.appendChild(shelf(ctx, t('favorites'), 'station', responses[1].value, 'radio-favorites'));
      }
      if (responses[0].error) { results.appendChild(errorBox(responses[0].error.message, () => load(append))); return; }
      const stations = responses[0].value;
      const oldMore = results.querySelector('.load-more'); if (oldMore) oldMore.remove();
      if (stations.length) results.appendChild(shelf(ctx, query ? t('search') : t('popular'), 'station', stations, 'radio-' + offset));
      offset += stations.length;
      if (stations.length === 50) results.appendChild(button(t('more'), () => load(true), 'radio-more', 'button load-more'));
      if (!results.childElementCount) results.textContent = t('noResults');
      if (append) ctx.nav.focus(results.querySelector('[data-row="radio-' + (offset - stations.length) + '"] [data-focusable]'));
    } catch (error) { if (!disposed && current === version) { results.textContent = ''; results.appendChild(errorBox(error.message, () => load(false))); } }
  }
  await load(false);
  return { node: root, dispose: () => { disposed = true; version++; clearTimeout(timer); } };
}
