// Pure geometry is shared with the Node tests. Rectangles must use the same coordinate system.
export function nearestInDirection(origin, candidates, direction) {
  const horizontal = direction === 'left' || direction === 'right';
  const sign = direction === 'left' || direction === 'up' ? -1 : 1;
  const cx = (origin.left + origin.right) / 2;
  const cy = (origin.top + origin.bottom) / 2;
  let best = null;
  let bestScore = Infinity;
  candidates.forEach(candidate => {
    const r = candidate.rect;
    const dx = (r.left + r.right) / 2 - cx;
    const dy = (r.top + r.bottom) / 2 - cy;
    const primary = (horizontal ? dx : dy) * sign;
    if (primary < 1) return;
    const cross = Math.abs(horizontal ? dy : dx);
    const overlap = horizontal ? Math.min(origin.bottom, r.bottom) - Math.max(origin.top, r.top) :
      Math.min(origin.right, r.right) - Math.max(origin.left, r.left);
    const score = primary + cross * 2.5 + (overlap > 0 ? 0 : 1000);
    if (score < bestScore) { bestScore = score; best = candidate; }
  });
  return best;
}
export class Navigation {
  constructor(root) {
    this.root = root;
    this.scope = root;
  }
  elements(scope) {
    return Array.from((scope || this.scope).querySelectorAll('[data-focusable]')).filter(el =>
      !el.disabled && !el.closest('[hidden]') && el.getClientRects().length > 0);
  }
  focus(el) {
    if (!el) return;
    el.focus({ preventScroll: true });
    // Instant: smooth scrolling on every key press (and key repeat) makes the TV browser lag behind the remote.
    el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    // The first row of a page (detail buttons, first shelf) scrolls the page to its top so the title above shows again;
    // a shelf shows its heading too.
    const view = el.closest('[data-scroll-root]');
    const first = view && view.querySelector('[data-focusable]');
    if (first && first.closest('[data-row]') === el.closest('[data-row]')) view.scrollTop = 0;
    else if (el.closest('.shelf')) el.closest('.shelf').scrollIntoView({ block: 'nearest' });
  }
  first(scope) { this.focus(this.elements(scope)[0]); }
  move(direction, excludedRoot) {
    const elements = this.elements();
    const current = document.activeElement;
    if (elements.indexOf(current) < 0) { this.focus(elements[0]); return; }
    const candidates = elements.filter(el => el !== current && (!excludedRoot || !excludedRoot.contains(el)))
      .map(el => ({ el: el, rect: el.getBoundingClientRect() }));
    const origin = current.getBoundingClientRect();
    // Stay in the scrolling page while it has more below/above: the mini player at the bottom edge is
    // nearer than the next shelf outside the screen, and focusing it first made every second step land there.
    const scroll = current.closest('[data-scroll-root]');
    const found = (scroll && nearestInDirection(origin, candidates.filter(c => scroll.contains(c.el)), direction)) ||
      nearestInDirection(origin, candidates, direction);
    if (!found) return;
    let target = found.el;
    const row = target.closest('[data-row]');
    if ((direction === 'up' || direction === 'down') && row && row !== current.closest('[data-row]')) {
      // Straight up/down: the card of the target row most in line with the current one (the most covered,
      // then the nearest column); from a wide row such as a track that is the row's first button.
      const center = (origin.left + origin.right) / 2;
      let best = null;
      candidates.forEach(c => {
        if (c.el.closest('[data-row]') !== row) return;
        const covered = Math.max(0, Math.min(origin.right, c.rect.right) - Math.max(origin.left, c.rect.left)) / (c.rect.right - c.rect.left || 1);
        const distance = Math.abs((c.rect.left + c.rect.right) / 2 - center);
        if (!best || covered > best.covered + 0.01 || (Math.abs(covered - best.covered) <= 0.01 && covered < 0.99 && distance < best.distance) ||
          (Math.abs(covered - best.covered) <= 0.01 && covered >= 0.99 && c.rect.left < best.left)) {
          best = { covered: covered, distance: distance, left: c.rect.left }; target = c.el;
        }
      });
    }
    this.focus(target);
  }
  restore(id, scope) {
    const target = this.elements(scope).filter(el => el.dataset.focusId === id)[0];
    if (target) this.focus(target); else this.focus(this.elements(scope)[0] || this.elements()[0]);
  }
}
