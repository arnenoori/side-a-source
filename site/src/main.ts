import './style.css';
import { analytics } from './analytics';
import { initLoveEggs } from './love-egg';
import { latestDownloadableRelease, releaseAPI, releasesURL } from './release.mjs';
import { platformDownloads, visitorPlatform } from './platform.mjs';

analytics.capture('$pageview');
// oxlint-disable-next-line no-console -- the console greeting is the point.
console.log('%cSide A%c  Read the source: https://github.com/arnenoori/side-a-source  (and try the Konami code)', 'font-weight:600', 'color:#657069');
const analyticsToggle = document.querySelector<HTMLInputElement>('#analytics-enabled')!;
analyticsToggle.checked = analytics.isEnabled();
analyticsToggle.disabled = analytics.privacySignal();
analyticsToggle.addEventListener('change', () => analytics.setDisabled(!analyticsToggle.checked));

document.querySelectorAll<HTMLButtonElement>('[data-dialog]').forEach(button => {
  button.addEventListener('click', () => (document.getElementById(button.dataset.dialog!) as HTMLDialogElement).showModal());
});
document.querySelectorAll<HTMLDialogElement>('dialog').forEach(dialog => {
  dialog.querySelector('[data-close]')?.addEventListener('click', () => dialog.close());
  dialog.addEventListener('click', event => { if (event.target === dialog) { const r = dialog.getBoundingClientRect(); if (event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom) dialog.close(); } });
});

const download = document.querySelector<HTMLAnchorElement>('#download')!;
const visitor = visitorPlatform(navigator);
const theirs = visitor === 'mac' ? null : platformDownloads[visitor];
if (theirs) {
  for (const link of document.querySelectorAll<HTMLAnchorElement>('#download, [data-download=cta]')) {
    link.removeAttribute('data-download');
    link.href = theirs.href;
  }
  const heading = document.querySelector('#download-label');
  if (heading) heading.textContent = theirs.label;
  const other = document.querySelector<HTMLAnchorElement>('#also-other');
  if (other) { other.textContent = theirs.other.label; other.href = theirs.other.href; }
  document.querySelector('#also')?.removeAttribute('hidden');
}
const downloads = [...document.querySelectorAll<HTMLAnchorElement>('[data-download]')];
const setDownload = (href: string, disabled = false) => downloads.forEach(link => {
  link.href = href;
  if (disabled) link.setAttribute('aria-disabled', 'true'); else link.removeAttribute('aria-disabled');
});
const label = theirs ? document.createElement('span') : document.querySelector('#download-label')!;
const status = document.querySelector('#release-status')!;
let downloadVersion: string | undefined;
downloads.forEach(link => link.addEventListener('click', event => {
  if (link.getAttribute('aria-disabled') === 'true') { event.preventDefault(); return; }
  if (downloadVersion) analytics.capture('download_clicked', { version: downloadVersion, source: link.dataset.download || 'hero' });
  else if (link.href === releasesURL) analytics.capture('release_list_opened');
}));
async function loadRelease() {
  try {
    const response = await fetch(releaseAPI, { signal: AbortSignal.timeout(7000), credentials: 'omit', headers: { Accept: 'application/vnd.github+json' } });
    if (!response.ok && response.status !== 404) throw new Error('Release lookup unavailable');
    const release = response.ok ? latestDownloadableRelease(await response.json()) : null;
    if (release) {
      setDownload(release.url);
      downloadVersion = release.version;
      label.textContent = 'Download for Mac';
      status.textContent = `v${release.version} · ${(release.size / 1048576).toFixed(1)} MB · Free public preview`;
    } else {
      setDownload(download.href, true);
      label.textContent = 'Coming soon';
      status.textContent = 'The first signed download is on its way.';
    }
  } catch {
    analytics.capture('release_lookup_failed');
    setDownload(releasesURL);
    label.textContent = 'View downloads';
    status.textContent = 'Check available versions on GitHub.';
  }
}
void loadRelease();
const fallback = document.querySelector<HTMLImageElement>('#fallback')!;
const connection = (navigator as Navigator & { connection?: { saveData?: boolean } }).connection;
const lightweight = matchMedia('(prefers-reduced-motion: reduce), (max-width: 600px), (pointer: coarse)').matches
  || connection?.saveData === true || (navigator.hardwareConcurrency || 8) <= 4;
const idle = () => new Promise<void>(resolve => ('requestIdleCallback' in window
  ? requestIdleCallback(() => resolve(), { timeout: 2000 }) : setTimeout(resolve, 200)));
if (lightweight) {
  document.querySelector<HTMLCanvasElement>('#player')!.hidden = true;
} else {
  void fallback.decode().catch(() => {}).then(idle).then(() => import('./player')).then(({ startPlayer }) => startPlayer()).catch(error => {
    analytics.capture('demo_load_failed');
    console.warn('Interactive preview unavailable; showing the product image.', error);
    document.querySelector<HTMLCanvasElement>('#player')!.hidden = true;
  });
}

// WebMCP is progressive enhancement: current draft uses document; early browsers use navigator.
// These tools only expose the same public information a visitor can read on the page.
import { createAgentTools } from './agent-tools.mjs';
type ModelContext = { registerTool: (tool: ReturnType<typeof createAgentTools>[number]) => void | Promise<void> };
const modelContext = (document as Document & { modelContext?: ModelContext }).modelContext
  ?? (navigator as Navigator & { modelContext?: ModelContext }).modelContext;
if (modelContext?.registerTool) {
  for (const tool of createAgentTools()) {
    try { void Promise.resolve(modelContext.registerTool(tool)).catch(() => {}); } catch { /* Early implementations may differ. */ }
  }
}

const mark = document.querySelector<HTMLElement>('.disc-mark');
let turns = 0, taps = 0, lastTap = 0;
mark?.addEventListener('click', event => {
  event.preventDefault();
  mark.style.transform = `rotate(${++turns * 180}deg)`;
  taps = performance.now() - lastTap < 600 ? taps + 1 : 1;
  lastTap = performance.now();
  if (taps === 5) { taps = 0; dispatchEvent(new Event('sidea:shuffle')); }
});

initLoveEggs();

const how = document.querySelector<HTMLElement>('#how');
if (how) {
  let started = false;
  const loadHow = () => {
    if (started) return;
    started = true;
    // oxlint-disable-next-line promise/always-return -- the callback ends the chain; the catch below is the handler.
    import('./how').then(({ mountHow }) => {
      mountHow(how);
      const target = location.hash.length > 1 ? document.getElementById(location.hash.slice(1)) : null;
      if (target && how.contains(target)) target.scrollIntoView();
    }).catch(error => console.warn('How it works demos unavailable.', error));
  };
  if (location.hash.length > 1) loadHow();
  for (const type of ['scroll', 'keydown', 'pointerdown', 'hashchange']) addEventListener(type, loadHow, { once: true, passive: true });
  addEventListener('load', () => ('requestIdleCallback' in window ? requestIdleCallback(loadHow, { timeout: 3000 }) : setTimeout(loadHow, 1500)));
}
