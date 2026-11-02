import './love-egg.css';
import { createLinger, createPress } from './linger.mjs';

const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
let playing = false;

// three.js and the heart load only when the effect fires, so the page's own script stays small.
function play(source: HTMLElement) {
  if (playing || reducedMotion.matches || document.hidden) return;
  playing = true;
  import('./heart3d')
    .then(({ playHeart }) => playHeart(source))
    .catch(() => {})
    .finally(() => { playing = false; });
}

export function initLoveEgg(source: HTMLElement) {
  if (source.dataset.loveEggReady) return;
  source.dataset.loveEggReady = '1';
  const bubble = document.createElement('span');
  bubble.className = 'love-bubble';
  const text = document.createElement('span');
  text.className = 'love-text';
  text.append(...source.childNodes);
  bubble.append(text);
  source.append(bubble);
  // A rest that ends while the last heart is still in the air waits again, so the next play still comes.
  const linger = createLinger({ delay: 2800, onFire: () => {
    if (playing) { linger.leave(); linger.enter(); } else play(source);
  } });
  const press = createPress({
    onStart: () => source.classList.add('pressing'),
    onCancel: () => source.classList.remove('pressing'),
    onFire: () => { source.classList.remove('pressing'); play(source); },
  });
  const mouse = (e: PointerEvent) => e.pointerType === 'mouse';
  source.addEventListener('pointerenter', e => { if (mouse(e)) linger.enter(); });
  source.addEventListener('pointermove', e => {
    if (mouse(e)) linger.move(); else press.move(e.clientX, e.clientY);
  });
  source.addEventListener('pointerleave', e => { if (mouse(e)) linger.leave(); });
  let touching = false;
  source.addEventListener('pointerdown', e => {
    touching = !mouse(e);
    if (touching && e.isPrimary && !playing && !reducedMotion.matches) press.down(e.clientX, e.clientY);
  });
  source.addEventListener('pointerup', () => press.up());
  source.addEventListener('pointercancel', () => press.up());
  // The finger that fired the egg lifts on the link; that tap is the egg's, not a visit to the link.
  source.addEventListener('click', e => { if (press.consume()) e.preventDefault(); });
  source.addEventListener('contextmenu', e => { if (touching) e.preventDefault(); });
  document.addEventListener('visibilitychange', () => { if (document.hidden) { linger.leave(); press.up(); } });
}

export function initLoveEggs(root: ParentNode = document) {
  root.querySelectorAll<HTMLElement>('[data-love-egg]').forEach(initLoveEgg);
}
