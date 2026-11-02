import './keep-awake.css';
import { macSleeps } from './demo-core.mjs';

const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
// The app's 2-minute grace, told in under 3 seconds.
const GRACE = 2600;

export function mountKeepAwake(scene: HTMLElement) {
  const $ = <T extends HTMLElement = HTMLElement>(sel: string) => scene.querySelector<T>(sel)!;
  const lap = $('.lap');
  const lidButton = $<HTMLButtonElement>('[data-ka-lid]');
  const awakeSwitch = $<HTMLButtonElement>('[data-ka-awake]');
  const lidSwitch = $<HTMLButtonElement>('[data-ka-closed]');
  const status = $('[data-ka-status]');
  const count = $('[data-ka-count]');
  const again = $<HTMLButtonElement>('[data-ka-again]');
  const rows = [...scene.querySelectorAll<HTMLElement>('.ka-row')].map(el => ({
    el, bar: el.querySelector<HTMLElement>('.mini-bar')!, sub: el.querySelector<HTMLElement>('.ka-sub')!,
    busy: el.querySelector('.ka-sub')!.textContent!, start: Number(el.dataset.start), rate: Number(el.dataset.rate), p: 0,
  }));

  let closed = false, asleep = false, visible = false, touched = false, armed = false;
  let doneAt = 0, last = 0, frame = 0;
  const on = (sw: HTMLElement) => sw.getAttribute('aria-checked') === 'true';
  const working = () => rows.filter(r => r.p < 1).length;

  const render = () => {
    const n = working();
    lap.style.setProperty('--f', closed ? '1' : '0');
    scene.classList.toggle('night', closed);
    scene.classList.toggle('asleep', asleep);
    scene.classList.toggle('done', !n);
    lidButton.textContent = closed ? 'Open the lid' : 'Close the lid';
    lidSwitch.disabled = !on(awakeSwitch);
    for (const r of rows) {
      r.bar.style.setProperty('--p', String(Math.min(r.p, 1) * 100));
      const done = r.p >= 1;
      if (r.el.classList.contains('finished') !== done) {
        r.el.classList.toggle('finished', done);
        r.sub.textContent = done ? r.sub.dataset.done! : r.busy;
      }
    }
    count.textContent = n ? `${n} working` : 'Done';
    const text = !n ? 'All agents done · Mac can sleep'
      : asleep ? 'Mac asleep · agents paused'
      : !on(awakeSwitch) ? 'Your Mac may sleep before they finish'
      : closed ? `Lid closed · ${n} working`
      : 'Keeping your Mac awake';
    if (status.textContent !== text) status.textContent = text;
    again.hidden = !!n;
  };

  const settle = (now = performance.now()) => {
    const n = working();
    if (!n && !doneAt) doneAt = now;
    if (!asleep) asleep = macSleeps({ keepAwake: on(awakeSwitch), lidOption: on(lidSwitch), lidClosed: closed, working: n > 0, idleMs: doneAt ? now - doneAt : 0 }, GRACE);
    render();
    const run = visible && !asleep && (n > 0 || on(awakeSwitch));
    if (run && !frame) { last = now; frame = requestAnimationFrame(tick); }
    if (!run && frame) { cancelAnimationFrame(frame); frame = 0; }
  };

  const tick = (now: number) => {
    frame = 0;
    const dt = Math.min(now - last, 100) / 1000;
    last = now;
    for (const r of rows) if (r.p < 1) r.p = Math.min(1, r.p + r.rate * dt);
    settle(now);
  };

  const setLid = (shut: boolean) => {
    touched = true;
    if (closed === shut) return render();
    closed = shut;
    if (!shut) { asleep = false; if (doneAt) doneAt = performance.now(); }
    settle();
  };

  const reset = () => {
    for (const r of rows) r.p = r.start;
    doneAt = 0;
    asleep = false;
  };

  lidButton.addEventListener('click', () => setLid(!closed));
  again.addEventListener('click', () => { touched = true; reset(); closed = false; settle(); lidButton.focus(); });
  for (const sw of [awakeSwitch, lidSwitch]) sw.addEventListener('click', () => {
    touched = true;
    sw.setAttribute('aria-checked', String(!on(sw)));
    settle();
  });

  let drag: { y: number; from: number; f: number } | null = null;
  lap.addEventListener('pointerdown', e => {
    if (!e.isPrimary) return;
    drag = { y: e.clientY, from: closed ? 1 : 0, f: closed ? 1 : 0 };
    lap.setPointerCapture(e.pointerId);
    lap.classList.add('dragging');
  });
  lap.addEventListener('pointermove', e => {
    if (!drag) return;
    drag.f = Math.max(0, Math.min(1, drag.from + (e.clientY - drag.y) / 130));
    lap.style.setProperty('--f', String(drag.f));
  });
  const release = (e: PointerEvent) => {
    if (!drag) return;
    const moved = Math.abs(e.clientY - drag.y) > 4;
    const shut = moved ? drag.f > 0.5 : !closed;
    drag = null;
    lap.classList.remove('dragging');
    setLid(shut);
  };
  lap.addEventListener('pointerup', release);
  lap.addEventListener('pointercancel', release);

  new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    if (visible && !touched && !armed && !reducedMotion.matches) {
      armed = true;
      setTimeout(() => { if (!touched && visible) setLid(true); }, 2200);
    }
    settle();
  }, { threshold: 0.35 }).observe(scene);

  reset();
  render();
}
