import { formatMemory, memoryWarning } from './demo-core.mjs';

const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');

export function mountLiveMock(desk: HTMLElement) {
  const $ = <T extends HTMLElement = HTMLElement>(sel: string, root: ParentNode = desk) => root.querySelector<T>(sel)!;
  const $$ = <T extends HTMLElement = HTMLElement>(sel: string, root: ParentNode = desk) => [...root.querySelectorAll<T>(sel)];
  const later = (ms: number, run: () => void) => window.setTimeout(run, ms);

  const tabs = $$<HTMLButtonElement>('[role=tab]');
  const title = $('.mw-title');
  const select = (tab: HTMLButtonElement, focus = false) => {
    for (const t of tabs) {
      const on = t === tab;
      t.setAttribute('aria-selected', String(on));
      t.tabIndex = on ? 0 : -1;
      document.getElementById(t.getAttribute('aria-controls')!)!.hidden = !on;
    }
    title.textContent = tab.textContent!.trim();
    if (focus) tab.focus();
  };
  tabs.forEach((tab, i) => {
    tab.addEventListener('click', () => select(tab));
    tab.addEventListener('keydown', e => {
      const step = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
      if (!step) return;
      e.preventDefault();
      select(tabs[(i + step + tabs.length) % tabs.length], true);
    });
  });

  const rows = $$<HTMLLIElement>('.lv-row');
  const note = $('[data-note]');
  const undo = $<HTMLButtonElement>('[data-undo]');
  const mb = (row: HTMLElement) => Number(row.dataset.mb);
  const live = () => rows.filter(r => !r.classList.contains('gone'));

  const render = () => {
    for (const row of rows) {
      const chip = $('.chip.mem', row);
      chip.textContent = formatMemory(mb(row));
      chip.classList.toggle('warn', mb(row) >= 1024 * 3);
      const procs = Number(row.dataset.procs);
      $('.lv-procs', row).textContent = `${procs} processes`;
      chip.title = `${procs} processes`;
    }
    const alive = live();
    const total = alive.reduce((sum, r) => sum + mb(r), 0);
    const idle = alive.filter(r => r.hasAttribute('data-idle'));
    $('[data-n=sessions]').textContent = String(alive.length);
    $('[data-n=working]').textContent = String(alive.filter(r => r.hasAttribute('data-busy')).length);
    $('[data-n=memory]').textContent = formatMemory(total);
    const warning = memoryWarning(total);
    const tight = $('[data-tight]');
    tight.classList.toggle('clear', !warning);
    if (warning) $('[data-tight-text]').textContent = warning;
    const stale = $('[data-stale]');
    stale.classList.toggle('clear', !idle.length);
    $('[data-stale-text]').textContent = `${idle.length} idle 30+ min · ${formatMemory(idle.reduce((s, r) => s + mb(r), 0))}`;
    $<HTMLButtonElement>('[data-quit-idle]').disabled = !idle.length;
  };

  let freed = 0;
  const say = (text: string, canUndo: boolean) => {
    note.textContent = text;
    undo.hidden = !canUndo;
  };
  const quit = (targets: HTMLElement[]) => {
    if (!targets.length) return;
    const total = targets.reduce((s, r) => s + mb(r), 0);
    freed += total;
    for (const row of targets) {
      row.style.setProperty('--row-h', `${row.offsetHeight}px`);
      row.classList.add('going');
      $$<HTMLButtonElement>('button', row).forEach(b => { b.disabled = true; });
      later(reducedMotion.matches ? 0 : 380, () => { row.classList.add('gone'); row.inert = true; render(); });
    }
    const names = targets.map(r => r.dataset.name).join(' and ');
    say(`Quit ${names}. Freed ${formatMemory(freed)}. Resume with claude --resume.`, true);
  };
  $$<HTMLButtonElement>('[data-quit]').forEach(b => b.addEventListener('click', () => quit([b.closest('li')!])));
  $<HTMLButtonElement>('[data-quit-idle]').addEventListener('click', () => quit(live().filter(r => r.hasAttribute('data-idle'))));
  undo.addEventListener('click', () => {
    for (const row of rows) {
      row.classList.remove('going', 'gone');
      row.inert = false;
      $$<HTMLButtonElement>('[data-quit]', row).forEach(b => { b.disabled = false; });
    }
    freed = 0;
    say('', false);
    render();
  });

  for (const port of $$<HTMLButtonElement>('.chip.port')) {
    port.setAttribute('aria-label', `Stop the server on port ${port.dataset.port}`);
    port.title = `localhost:${port.dataset.port} · ${port.dataset.cmd}`;
    port.addEventListener('click', () => {
      const row = port.closest<HTMLElement>('li')!;
      const sub = $('.lv-sub', row);
      const prior = sub.textContent!;
      const confirm = document.createElement('span');
      confirm.className = 'lv-confirm';
      confirm.innerHTML = `<span>Stop ${port.dataset.cmd} on :${port.dataset.port}?</span><button type="button" class="link-btn" data-no>Cancel</button><button type="button" class="link-btn danger" data-yes>Stop Server</button>`;
      sub.hidden = true;
      sub.after(confirm);
      const close = () => { confirm.remove(); sub.hidden = false; };
      $<HTMLButtonElement>('[data-yes]', confirm).focus({ preventScroll: true });
      $('[data-no]', confirm).addEventListener('click', () => { close(); port.focus({ preventScroll: true }); });
      $('[data-yes]', confirm).addEventListener('click', () => {
        close();
        row.dataset.mb = String(mb(row) - Number(port.dataset.mb));
        row.dataset.procs = String(Math.max(1, Number(row.dataset.procs) - 1));
        sub.textContent = `Stopped :${port.dataset.port}. The session keeps running.`;
        port.remove();
        render();
        later(3200, () => { sub.textContent = prior; });
      });
      confirm.addEventListener('keydown', e => { if (e.key === 'Escape') { close(); port.focus({ preventScroll: true }); } });
    });
  }
  render();

  for (const bar of $$('[data-p]')) $('i', bar).style.setProperty('--p', bar.dataset.p!);
  const archive = $<HTMLButtonElement>('[data-archive]');
  let archived = false;
  archive.addEventListener('click', () => {
    archived = !archived;
    archive.textContent = archived ? 'Restore' : 'Archive';
    $('[data-disk]').textContent = archived ? '1.8 GB · Claude 1.5 GB · Codex 300 MB' : '2.8 GB · Claude 2.3 GB · Codex 530 MB';
    $('[data-old]').textContent = archived ? 'Moved 318 conversations, 1.05 GB, to the archive' : '318 conversations, 1.05 GB';
    $('[data-old-note]').textContent = archived ? 'Nothing was deleted. Restore puts them back.' : 'Untouched for 90 days. Pinned and running ones stay.';
  });
  for (const remove of $$<HTMLButtonElement>('[data-remove]')) {
    remove.addEventListener('click', () => {
      const row = remove.closest<HTMLElement>('.f-row')!;
      row.style.setProperty('--row-h', `${row.offsetHeight}px`);
      row.classList.add('going');
      remove.disabled = true;
      later(reducedMotion.matches ? 0 : 380, () => {
        const section = row.parentElement!;
        row.remove();
        if (!section.querySelector('.f-row')) {
          const empty = document.createElement('div');
          empty.className = 'f-row';
          empty.innerHTML = '<span class="sec">Removed. The branch stays in the repository.</span>';
          section.append(empty);
        }
      });
    });
  }

  const check = $<HTMLButtonElement>('[data-check]');
  check.addEventListener('click', () => {
    check.disabled = true;
    check.textContent = 'Checking…';
    later(reducedMotion.matches ? 200 : 1100, () => {
      for (const srv of $$('.srv')) {
        const status = srv.dataset.srv;
        srv.classList.add(status ?? 'unchecked');
        $('.dot', srv).setAttribute('aria-label', status === 'connected' ? 'Connected' : status === 'failed' ? 'Failed' : 'Off');
      }
      check.textContent = 'Check connections';
      check.disabled = false;
    });
  });
}
