// The Linux page asks GitHub for the sidead release and does nothing else with the network.
import './style.css';
import './doc.css';
import './linux.css';
import { latestSideadRelease, releaseAPI, releasesURL } from './release.mjs';

const status = document.getElementById('linux-status');
const install = document.getElementById('linux-install');
const copy = document.getElementById('copy-command');
const command = document.getElementById('install-command');
const setLink = (name: string, href: string) => {
  const anchor = document.querySelector<HTMLAnchorElement>(`[data-package="${name}"]`);
  if (anchor) anchor.href = href;
};

async function load() {
  try {
    const response = await fetch(releaseAPI, { signal: AbortSignal.timeout(7000), credentials: 'omit', headers: { Accept: 'application/vnd.github+json' } });
    if (!response.ok && response.status !== 404) throw new Error('Release lookup unavailable');
    const release = response.ok ? latestSideadRelease(await response.json()) : null;
    if (!release) return; // "Coming soon" stays until a sidead release is published.
    for (const arch of ['amd64', 'arm64']) {
      const files = release.packages[arch];
      if (!files) continue;
      setLink(`${arch}-tarball`, files.tarball);
      setLink(`${arch}-deb`, files.deb);
    }
    setLink('checksums', release.checksums);
    if (install) install.hidden = false;
    if (status) status.textContent = `Version ${release.version}`;
  } catch {
    status?.replaceChildren(Object.assign(document.createElement('a'), { href: releasesURL, textContent: 'View downloads' }));
  }
}
void load();

async function copyCommand() {
  if (!copy) return;
  try {
    await navigator.clipboard.writeText(command?.textContent ?? '');
    copy.textContent = 'Copied';
  } catch { copy.textContent = 'Select and copy'; }
  setTimeout(() => { copy.textContent = 'Copy'; }, 2000);
}
copy?.addEventListener('click', () => { void copyCommand(); });
