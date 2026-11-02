import './app-mock.css';

const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
type WindowState = 'open' | 'closed' | 'minimized';

export function mountAppMock(desk: HTMLElement) {
  const win = desk.querySelector<HTMLElement>('.mw')!;
  const showWindow = (how: WindowState) => {
    win.classList.remove('closed', 'minimized');
    if (how !== 'open') win.classList.add(how);
    win.inert = how !== 'open';
  };
  mountEasterEggs(desk, showWindow);
  const $ = <T extends Element = HTMLElement>(sel: string, root: ParentNode = desk) => root.querySelector<T & Element>(sel) as T | null;
  const $$ = <T extends Element = HTMLElement>(sel: string, root: ParentNode = desk) => [...root.querySelectorAll(sel)] as T[];
  const later = (ms: number, run: () => void) => window.setTimeout(run, ms);

  const meter = (el: HTMLElement, pct: number) => {
    el.dataset.pct = String(pct);
    el.classList.toggle('warn', pct >= 75 && pct < 98);
    el.classList.toggle('full', pct >= 98);
    el.querySelector<HTMLElement>('.mini-bar i')?.style.setProperty('--p', String(pct));
  };
  const meters = $$('[data-pct]');
  const fill = () => meters.forEach(el => meter(el, el.hasAttribute('data-empty') ? 0 : Number(el.dataset.pct)));

  const days = [0.9, 1.4, 2.0, 1.0, 1.6, 0.8, 0.4, 1.7, 2.3, 1.3, 1.9, 0.9, 0.5, 0.7, 1.0, 1.6, 2.2, 1.2, 1.8, 0.8, 0.5, 1.9, 0.9, 1.5, 2.0, 1.0, 0.6, 0.8, 1.2, 1.7];
  const bars = $('.bars');
  if (bars) {
    days.forEach((total, i) => {
      const bar = document.createElement('span');
      bar.style.setProperty('--h', String((total / 3) * 100));
      bar.title = `${total.toFixed(1)}B tokens`;
      const opus = 0.78 + ((i * 7) % 5) / 50;
      for (const share of [opus, 1 - opus]) {
        const seg = document.createElement('i');
        seg.style.setProperty('--s', share.toFixed(3));
        bar.append(seg);
      }
      bar.style.transitionDelay = `${i * 12}ms`;
      bars.append(bar);
    });
  }

  new IntersectionObserver((entries, observer) => {
    if (!entries.some(e => e.isIntersecting)) return;
    observer.disconnect();
    requestAnimationFrame(() => { fill(); $('.chart')?.classList.add('shown'); });
  }, { threshold: 0.15 }).observe(desk);

  const tabs = $$<HTMLButtonElement>('[role=tab]');
  const title = $('.mw-title');
  const sessions = document.getElementById('mp-sessions');
  // Sessions is its own window in the app; the mock's window switches between it and Settings.
  const selectTab = (name: string, focus = false) => {
    const own = name === 'sessions';
    win.dataset.mode = own ? 'sessions' : 'settings';
    if (sessions) sessions.hidden = !own;
    if (own && title) title.textContent = 'Sessions';
    for (const tab of tabs) {
      const on = tab.dataset.tab === name;
      tab.setAttribute('aria-selected', String(on));
      tab.tabIndex = on ? 0 : -1;
      const pane = document.getElementById(tab.getAttribute('aria-controls') ?? '');
      if (pane) pane.hidden = !on;
      if (on) { if (title) title.textContent = tab.textContent?.trim() ?? ''; if (focus) tab.focus(); }
    }
    if (name === 'usage') $('.chart')?.classList.add('shown');
  };
  tabs.forEach((tab, i) => {
    tab.addEventListener('click', () => selectTab(tab.dataset.tab!));
    tab.addEventListener('keydown', e => {
      const step = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
      const to = step ? (i + step + tabs.length) % tabs.length : e.key === 'Home' ? 0 : e.key === 'End' ? tabs.length - 1 : -1;
      if (to < 0) return;
      e.preventDefault();
      selectTab(tabs[to].dataset.tab!, true);
    });
  });
  $$<HTMLButtonElement>('[data-open]').forEach(b => b.addEventListener('click', () => { showWindow('open'); selectTab(b.dataset.open!, true); }));

  let active = 'personal';
  let autopilot = true;
  const names: Record<string, string> = { personal: 'Personal', studio: 'Studio', weekend: 'Weekend' };
  const status = () => {
    const line = $('[data-autopilot-status]');
    if (line) line.textContent = autopilot ? `On. Using ${names[active]}. Warms up idle windows from 8:30.` : 'Off. Side A only shows your limits.';
    for (const row of $$('[data-rank]')) {
      const pick = row.dataset.rank === 'personal';
      row.classList.toggle('pick', pick);
      const tag = $('.rank-tag', row);
      if (tag && pick) tag.textContent = active === 'personal' ? 'In use' : 'Next';
    }
  };
  const setActive = (id: string) => {
    active = id;
    $$('[data-account]').forEach(row => row.classList.toggle('active', row.dataset.account === id));
    status();
  };
  $$<HTMLButtonElement>('[data-use]').forEach(b => b.addEventListener('click', e => { e.stopPropagation(); setActive(b.dataset.use!); }));
  $$('.mm-row[data-account]').forEach(row => row.addEventListener('click', () => setActive(row.dataset.account!)));
  setActive(active);

  $$<HTMLButtonElement>('.switch').forEach(sw => sw.addEventListener('click', () => {
    const on = sw.getAttribute('aria-checked') !== 'true';
    if (sw.hasAttribute('data-autopilot')) {
      autopilot = on;
      $$('[data-autopilot]').forEach(s => s.setAttribute('aria-checked', String(on)));
      status();
    } else sw.setAttribute('aria-checked', String(on));
  }));
  $$('.segmented').forEach(group => {
    const options = $$<HTMLButtonElement>('[role=radio]', group);
    options.forEach(option => option.addEventListener('click', () => {
      options.forEach(o => o.setAttribute('aria-checked', String(o === option)));
      const agent = $('[data-agent]');
      if (agent) agent.textContent = option.textContent;
    }));
  });

  const limited = $<HTMLButtonElement>('.mm-limited');
  limited?.addEventListener('click', () => {
    const open = limited.getAttribute('aria-expanded') !== 'true';
    limited.setAttribute('aria-expanded', String(open));
    const rows = document.getElementById(limited.getAttribute('aria-controls') ?? '');
    if (rows) rows.hidden = !open;
  });
  const refresh = $<HTMLButtonElement>('[data-refresh]');
  refresh?.addEventListener('click', () => {
    refresh.classList.remove('spinning');
    void refresh.offsetWidth;
    refresh.classList.add('spinning');
    meters.forEach(el => el.querySelector<HTMLElement>('.mini-bar i')?.style.setProperty('--p', '0'));
    later(reducedMotion.matches ? 0 : 260, fill);
  });

  let shown = false;
  new IntersectionObserver(entries => { shown = entries.some(e => e.isIntersecting); }).observe(desk);
  const live = $$('[data-live]');
  window.setInterval(() => {
    if (!shown || document.hidden) return;
    for (const el of live) {
      const next = Number(el.dataset.pct) >= 70 ? 62 : Number(el.dataset.pct) + 1;
      meter(el, next);
      const label = $('.mini-l', el);
      if (label) label.textContent = `5h ${next}%`;
    }
  }, 3200);

  const rows = $$<HTMLButtonElement>('.s-row');
  const views = $$('.v');
  const open = (id: string) => {
    rows.forEach(r => { if (r.dataset.session === id) r.setAttribute('aria-current', 'true'); else r.removeAttribute('aria-current'); });
    views.forEach(v => { v.hidden = v.dataset.view !== id; });
  };
  rows.forEach(r => r.addEventListener('click', () => open(r.dataset.session!)));

  const relabel = () => {
    for (const label of $$('.s-label')) {
      const group = label.dataset.label;
      label.hidden = !rows.some(r => r.dataset.group === group && !r.hidden);
    }
    const empty = $('.s-empty');
    if (empty) empty.hidden = rows.some(r => !r.hidden);
  };
  const moveTo = (row: HTMLElement, group: string) => {
    row.dataset.group = group;
    const label = $(`.s-label[data-label="${group}"]`);
    if (!label) return;
    const peers = rows.filter(r => r !== row && r.dataset.group === group);
    (peers[peers.length - 1] ?? label).after(row);
    relabel();
  };

  const search = $<HTMLInputElement>('.s-search input');
  search?.addEventListener('input', () => {
    const q = search.value.trim().toLowerCase();
    rows.forEach(r => { r.hidden = !!q && !(r.textContent ?? '').toLowerCase().includes(q); });
    relabel();
  });
  search?.addEventListener('keydown', e => { if (e.key === 'Escape') { search.value = ''; search.dispatchEvent(new Event('input')); } });

  const row = (id: string) => rows.find(r => r.dataset.session === id)!;
  const view = (id: string) => views.find(v => v.dataset.view === id)!;

  const api = view('api');
  let apiReset = 0;
  $$<HTMLButtonElement>('[data-answer]', api).forEach(b => b.addEventListener('click', () => {
    const answer = b.dataset.answer!;
    const allowed = answer !== 'Denied';
    const done = $('.req-done', api)!;
    done.textContent = allowed ? `${answer}. Running pytest -k retry.` : 'Denied. Claude Code will try another way.';
    api.classList.add('answered');
    const run = $('[data-run]', row('api'));
    if (run) run.textContent = allowed ? 'Running pytest -k retry' : 'Working';
    const late = $('.msg.late', api);
    if (late) late.textContent = allowed ? 'All 48 tests pass.' : "Okay, I won't run the tests. Checking the retry by reading the code instead.";
    row('api').classList.add('resolved');
    moveTo(row('api'), 'running');
    later(reducedMotion.matches ? 0 : 1100, () => api.classList.add('ran'));
    clearTimeout(apiReset);
    apiReset = later(7000, () => {
      api.classList.remove('answered', 'ran');
      row('api').classList.remove('resolved');
      moveTo(row('api'), 'waiting');
    });
  }));

  const docs = view('docs');
  const reply = $<HTMLFormElement>('.reply', docs);
  let docsReset = 0;
  reply?.addEventListener('submit', e => {
    e.preventDefault();
    const input = $<HTMLInputElement>('input', reply)!;
    const text = input.value.trim();
    if (!text) return;
    const msg = document.createElement('p');
    msg.className = 'msg user sent';
    msg.textContent = text;
    $('.v-body', docs)?.append(msg);
    input.value = '';
    row('docs').classList.add('resolved');
    moveTo(row('docs'), 'running');
    clearTimeout(docsReset);
    docsReset = later(8000, () => {
      $$('.sent', docs).forEach(m => m.remove());
      row('docs').classList.remove('resolved');
      moveTo(row('docs'), 'finished');
    });
  });

  const web = view('web');
  let webReset = 0;
  $$<HTMLButtonElement>('[data-mail]', web).forEach(b => b.addEventListener('click', () => {
    const line = $('[data-mail-line]', row('web'));
    if (line) line.textContent = b.dataset.mail!;
    row('web').classList.add('resolved');
    clearTimeout(webReset);
    webReset = later(6000, () => row('web').classList.remove('resolved'));
  }));

  const steps = $('[data-steps]');
  if (steps) {
    const all = steps.dataset.steps!.split('|');
    let n = 0;
    window.setInterval(() => {
      if (!shown || document.hidden) return;
      n = (n + 1) % all.length;
      if (reducedMotion.matches) { steps.textContent = all[n]; return; }
      steps.classList.add('out');
      later(220, () => { steps.textContent = all[n]; steps.classList.remove('out'); });
    }, 2600);
  }

  relabel();
  open('api');
}

function mountEasterEggs(desk: HTMLElement, showWindow: (how: WindowState) => void) {
  const menu = desk.querySelector<HTMLElement>('.mm')!;
  const item = desk.querySelector<HTMLButtonElement>('.desk-status')!;
  const setMenu = (open: boolean) => {
    menu.classList.toggle('closed', !open);
    menu.inert = !open;
    item.setAttribute('aria-expanded', String(open));
  };
  item.addEventListener('click', () => setMenu(menu.classList.contains('closed')));
  menu.addEventListener('keydown', e => { if (e.key === 'Escape') { setMenu(false); item.focus(); } });

  desk.querySelectorAll<HTMLButtonElement>('[data-light]').forEach(light => light.addEventListener('click', () => {
    showWindow(light.dataset.light === 'close' ? 'closed' : 'minimized');
    item.focus({ preventScroll: true });
  }));

  desk.querySelector('[data-quit-app]')?.addEventListener('click', () => {
    setMenu(false);
    showWindow('closed');
    item.classList.add('gone');
    item.disabled = true;
    // Open at login is on, so Side A is straight back, just not in front.
    window.setTimeout(() => { item.classList.remove('gone'); item.disabled = false; }, 1800);
  });

  const spin = desk.querySelector<HTMLButtonElement>('[data-spin]');
  const disc = spin?.querySelector<SVGElement>('svg');
  if (spin && disc) {
    let angle = 0, velocity = 0, last = 0, frame = 0;
    const tick = (now: number) => {
      const dt = Math.min(0.05, (now - last) / 1000);
      last = now;
      velocity *= Math.exp(-1.4 * dt);
      angle = (angle + velocity * dt) % 360;
      disc.style.transform = `rotate(${angle}deg)`;
      frame = velocity > 6 ? requestAnimationFrame(tick) : 0;
    };
    spin.addEventListener('click', () => {
      if (reducedMotion.matches) return;
      velocity = Math.min(velocity + 1000, 3000);
      if (!frame) { last = performance.now(); frame = requestAnimationFrame(tick); }
    });
  }
}
