import './remote.css';

export function mountRemote(section: HTMLElement) {
  const panel = section.querySelector<HTMLElement>('.phone-screen')!;
  const screens = [...panel.querySelectorAll<HTMLElement>('[data-screen]')];
  const tabs = [...section.querySelectorAll<HTMLButtonElement>('[role=tab]')];
  for (const screen of screens) screen.hidden = false;
  const select = (tab: HTMLButtonElement, focus = false) => {
    for (const t of tabs) {
      const on = t === tab;
      t.setAttribute('aria-selected', String(on));
      t.tabIndex = on ? 0 : -1;
    }
    for (const screen of screens) {
      const on = screen.dataset.screen === tab.dataset.screen;
      screen.classList.toggle('on', on);
      screen.setAttribute('aria-hidden', String(!on));
    }
    panel.setAttribute('aria-labelledby', tab.id);
    if (focus) tab.focus();
  };
  tabs.forEach((tab, i) => {
    tab.addEventListener('click', () => select(tab));
    tab.addEventListener('keydown', e => {
      const step = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
      if (!step) return;
      e.preventDefault();
      const next = tabs[(i + step + tabs.length) % tabs.length];
      if (next) select(next, true);
    });
  });
  const first = tabs.find(t => t.getAttribute('aria-selected') === 'true') ?? tabs[0];
  if (first) select(first);
}
