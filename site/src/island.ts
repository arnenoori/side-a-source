import { islandShortcut } from './demo-core.mjs';

type State = 'rest' | 'compact' | 'ask' | 'ok' | 'done' | 'reply';
type Item =
  | { kind: 'ask'; agent: 'claude' | 'codex'; title: string; place: string; cmd: string; prompt: string; ran: string }
  | { kind: 'done'; agent: 'claude' | 'codex'; title: string; summary: string; prompt: string };

const items: Item[] = [
  { kind: 'ask', agent: 'claude', title: 'api', place: 'Personal', cmd: 'pytest -k retry', prompt: 'fix the retry and run the tests', ran: '48 passed in 3.1s' },
  { kind: 'done', agent: 'claude', title: 'docs', summary: 'Added the changelog entry.', prompt: 'add a changelog entry for the retry fix' },
  { kind: 'ask', agent: 'codex', title: 'web', place: 'Work', cmd: 'npm run build', prompt: 'ship the new pricing page', ran: 'Built in 4.2s' },
  { kind: 'done', agent: 'codex', title: 'api', summary: 'All 48 tests pass.', prompt: 'run the full test suite' },
];

const LARGE: State[] = ['ask', 'done', 'reply'];
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');

export function mountIsland(demo: HTMLElement, section: Element) {
  const $ = <T extends HTMLElement = HTMLElement>(sel: string, root: ParentNode = demo) => root.querySelector<T>(sel)!;
  const $$ = (sel: string) => [...demo.querySelectorAll<HTMLElement>(sel)];
  const screen = $('.screen');
  const island = $('.island');
  const panes = new Map($$('.pane').map(p => [p.dataset.pane as State, p]));
  const lines = $('.term-lines');
  const termWindow = $('.term');
  const announce = $('[data-announce]');
  const keys = $<HTMLButtonElement>('.keys');
  const letter = $('[data-key=letter]');
  const keysLabel = $('.keys-label');
  const field = $<HTMLInputElement>('.i-field');

  let state: State = 'rest';
  let index = 0;
  let timer = 0;
  let visible = false;
  let started = false;
  let collapsedAt = 0;
  const item = () => items[index % items.length];
  const later = (ms: number, run: () => void) => { clearTimeout(timer); timer = window.setTimeout(run, ms); };

  const glyph = (agent: Item['agent']) =>
    `<svg class="glyph ${agent}" aria-hidden="true"><use href="#i-${agent === 'claude' ? 'asterisk' : 'code'}" /></svg>`;

  const term = (rows: [string, string?][]) => {
    lines.replaceChildren(...rows.map(([text, cls]) => {
      const p = document.createElement('p');
      p.textContent = text;
      if (cls) p.className = cls;
      return p;
    }));
  };

  const fit = () => {
    const w = screen.clientWidth;
    const notch = Math.round(Math.min(132, Math.max(92, w * 0.22)));
    island.style.setProperty('--notch-w', `${notch}px`);
    island.style.setProperty('--card-w', `${Math.min(460, w - 16)}px`);
    island.style.setProperty('--event-w', `${Math.min(380, w - 16)}px`);
    const pane = panes.get(state);
    island.style.setProperty('--w', pane ? `${pane.offsetWidth}px` : `${notch}px`);
    island.style.setProperty('--h', pane ? `${pane.offsetHeight}px` : 'var(--notch-h)');
  };

  const show = (next: State) => {
    state = next;
    demo.dataset.state = next;
    island.classList.toggle('large', LARGE.includes(next));
    for (const [name, pane] of panes) {
      const on = name === next;
      pane.classList.toggle('on', on);
      pane.inert = !on;
    }
    const current = item();
    const key = next === 'done' ? ['R', 'Reply'] : ['Y', 'Allow'];
    letter.textContent = key[0];
    keysLabel.textContent = key[1];
    keys.disabled = !(next === 'ask' || next === 'done' || next === 'compact');
    keys.setAttribute('aria-label', next === 'done' ? `Reply to ${current.title} (Control Option R)` : 'Allow (Control Option Y)');
    fit();
  };

  const arrive = () => {
    if (!visible) { started = false; return; }
    const current = item();
    for (const el of $$('[data-glyph]')) el.innerHTML = glyph(current.agent);
    for (const el of $$('[data-title]')) el.textContent = current.title;
    $('[data-agent]').textContent = current.agent === 'claude' ? 'Claude Code' : 'Codex';
    $('[data-term-title]').textContent = `${current.title} — ${current.agent}`;
    const compact = panes.get('compact')!;
    $('.strip-r', compact).innerHTML = current.kind === 'ask' ? '<span class="beacon"></span>' : '<svg class="result sent" aria-hidden="true"><use href="#i-check" /></svg>';
    compact.setAttribute('aria-label', current.kind === 'ask' ? 'A request is waiting. Open it.' : `${current.title} is done. Open it.`);
    if (current.kind === 'ask') {
      $('[data-place]').textContent = `  ·  ${current.place}`;
      $('[data-cmd]').textContent = current.cmd;
      term([[`> ${current.prompt}`], [`⏺ Bash(${current.cmd})`], ['  Waiting for permission…', 'wait']]);
      announce.textContent = `${current.agent === 'claude' ? 'Claude Code' : 'Codex'} wants to run ${current.cmd}`;
    } else {
      $('[data-summary]').textContent = current.summary;
      term([[`> ${current.prompt}`], [`⏺ ${current.summary}`, 'ran']]);
      announce.textContent = `${current.title} is done`;
    }
    show('compact');
    later(reducedMotion.matches ? 300 : 650, () => show(current.kind === 'ask' ? 'ask' : 'done'));
  };

  const settle = (result: 'allow' | 'deny' | 'sent', message: string) => {
    const mark = result === 'deny' ? 'x' : 'check';
    $('[data-result]').innerHTML = `<svg class="result ${result}" aria-hidden="true"><use href="#i-${mark}" /></svg>`;
    announce.textContent = message;
    show('ok');
    later(1300, () => {
      show('rest');
      index++;
      later(2400, arrive);
    });
  };

  const act = (action: string) => {
    const current = item();
    switch (action) {
      case 'expand': if (state === 'compact') show(current.kind === 'ask' ? 'ask' : 'done'); break;
      case 'collapse': case 'dismiss': collapsedAt = performance.now(); show(state === 'reply' ? 'done' : 'compact'); break;
      case 'allow': case 'always': case 'deny': {
        if (current.kind !== 'ask') return;
        const allowed = action !== 'deny';
        term([[`> ${current.prompt}`], [`⏺ Bash(${current.cmd})`], allowed ? [`  ${current.ran}`, 'ran'] : ['  Denied. Trying another way.', 'wait']]);
        settle(allowed ? 'allow' : 'deny', action === 'always' ? `Always allowed ${current.cmd.split(' ')[0]}` : allowed ? 'Allowed' : 'Denied');
        break;
      }
      case 'terminal': termWindow.classList.remove('raised'); void termWindow.offsetWidth; termWindow.classList.add('raised'); break;
      case 'reply': if (current.kind === 'done') { show('reply'); field.value = ''; field.focus({ preventScroll: true }); } break;
      case 'go': if (current.kind === 'done') { term([[`> ${current.prompt}`], [`⏺ ${current.summary}`, 'ran'], ['> ', 'cursor']]); settle('sent', `Showing ${current.title}`); } break;
    }
  };

  demo.addEventListener('click', e => {
    const target = (e.target as Element).closest<HTMLElement>('[data-act], [data-pane=compact]');
    if (!target) return;
    if (target.dataset.pane === 'compact') return act('expand');
    if (target.dataset.act === 'key') return act(state === 'done' ? 'reply' : state === 'compact' ? 'expand' : 'allow');
    act(target.dataset.act!);
  });
  $('[data-pane=compact]').addEventListener('pointerenter', () => { if (performance.now() - collapsedAt > 700) act('expand'); });

  $<HTMLFormElement>('.i-reply').addEventListener('submit', e => {
    e.preventDefault();
    const text = field.value.trim();
    if (!text) { field.focus(); return; }
    const current = item();
    if (current.kind !== 'done') return;
    term([[`> ${current.prompt}`], [`⏺ ${current.summary}`, 'ran'], [`> ${text}`]]);
    field.blur();
    settle('sent', `Sent to ${current.title}`);
  });

  const press = (on: boolean, code?: string) => {
    $('[data-key=ctrl]').classList.toggle('down', on);
    $('[data-key=opt]').classList.toggle('down', on);
    letter.classList.toggle('down', on && !!code && code === `Key${letter.textContent}`);
  };
  document.addEventListener('keydown', e => {
    if (!visible) return;
    if (e.ctrlKey && e.altKey) press(true, e.code);
    const action = islandShortcut(state, e);
    if (!action) return;
    if (e.key === 'Escape' && !demo.contains(document.activeElement)) return;
    e.preventDefault();
    act(action);
  });
  document.addEventListener('keyup', e => { if (!e.ctrlKey || !e.altKey) press(false); });

  new ResizeObserver(fit).observe(screen);
  show('rest');

  new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    if (visible && !started) { started = true; later(700, arrive); }
  }, { threshold: 0.35 }).observe(section);
}
