import { test } from 'node:test';
import assert from 'node:assert/strict';
import { downloadableRelease, latestDownloadableRelease, latestSideadRelease, releasesURL, sideadRelease } from '../src/release.mjs';
function fixture() {
  return { tag_name: 'v0.3.1', published_at: '2026-09-06', assets: ['SideA-0.3.1-macOS-universal.dmg', 'SHA256SUMS.txt'].map(name => ({ name, state: 'uploaded', size: 12345, browser_download_url: `${releasesURL}/download/v0.3.1/${name}` })) };
}
test('only a published release with DMG and checksum enables the download', () => { assert.equal(downloadableRelease(fixture()).version, '0.3.1'); });
test('drafts, previews, and incomplete uploads stay unavailable', () => {
  for (const patch of [{ draft: true }, { prerelease: true }, { published_at: null }, { assets: [] }]) assert.equal(downloadableRelease({ ...fixture(), ...patch }), null);
  const partial = fixture(); partial.assets[0].state = 'new'; assert.equal(downloadableRelease(partial), null);
});
test('another host or repository cannot become the download URL', () => {
  const release = fixture(); release.assets[0].browser_download_url = 'https://example.com/SideA.dmg'; assert.equal(downloadableRelease(release), null);
});
test('a missing checksum or mismatched version fails closed', () => {
  const release = fixture(); release.assets.pop(); assert.equal(downloadableRelease(release), null);
  assert.equal(downloadableRelease({ ...fixture(), tag_name: 'v1.0.0' }), null);
});
test('the release list cannot turn drafts, incomplete data, or malformed responses into downloads', () => {
  assert.equal(latestDownloadableRelease(null), null);
  assert.equal(latestDownloadableRelease({ assets: [] }), null);
  assert.equal(latestDownloadableRelease([{ draft: true }, { tag_name: 'v1.0.0' }]), null);
});

function sideadFixture(version = '0.1.0') {
  const names = ['SHA256SUMS.txt', ...['amd64', 'arm64'].flatMap(arch => [`side-a-daemon-${version}-linux-${arch}.tar.gz`, `side-a-daemon_${version}_${arch}.deb`])];
  return { tag_name: `sidead-v${version}`, published_at: '2026-11-25', assets: names.map(name => ({ name, state: 'uploaded', size: 29380445, browser_download_url: `${releasesURL}/download/sidead-v${version}/${name}` })) };
}
test('a published sidead release with both architectures and sums enables the Linux download', () => {
  const release = sideadRelease(sideadFixture());
  assert.equal(release.version, '0.1.0');
  assert.equal(release.packages.arm64.deb, `${releasesURL}/download/sidead-v0.1.0/side-a-daemon_0.1.0_arm64.deb`);
  assert.equal(release.checksums, `${releasesURL}/download/sidead-v0.1.0/SHA256SUMS.txt`);
});
test('sidead drafts, missing packages, missing sums and look-alike hosts stay unavailable', () => {
  for (const patch of [{ draft: true }, { prerelease: true }, { published_at: null }, { assets: [] }, { tag_name: 'sidead-v0.1.0-rc1' }, { tag_name: 'v0.1.0' }]) assert.equal(sideadRelease({ ...sideadFixture(), ...patch }), null);
  const noSums = sideadFixture(); noSums.assets.shift(); assert.equal(sideadRelease(noSums), null);
  const noArm = sideadFixture(); noArm.assets = noArm.assets.filter(item => !item.name.includes('arm64')); assert.equal(sideadRelease(noArm), null);
  const elsewhere = sideadFixture(); elsewhere.assets[1].browser_download_url = 'https://example.com/x.tar.gz'; assert.equal(sideadRelease(elsewhere), null);
});
test('a Mac release and a sidead release do not stand in for each other', () => {
  assert.equal(downloadableRelease(sideadFixture()), null);
  assert.equal(sideadRelease(fixture()), null);
  const list = [fixture(), sideadFixture('0.2.0'), sideadFixture('0.1.0')];
  assert.equal(latestSideadRelease(list).version, '0.2.0');
  assert.equal(latestDownloadableRelease(list).version, '0.3.1');
  assert.equal(latestSideadRelease([fixture()]), null);
  assert.equal(latestSideadRelease(null), null);
});

import { readFileSync } from 'node:fs';
const read = path => readFileSync(new URL(path, import.meta.url), 'utf8');
test('the Linux and Windows pages offer the one-liner the site really serves, and Windows says it is a preview', () => {
  for (const name of ['linux', 'windows']) {
    const page = read(`../${name}/index.html`);
    assert.match(page, /<code id="install-command">curl -fsSL https:\/\/getsidea\.com\/install\.sh \| sh<\/code>/);
    assert.match(page, /id="packages" hidden/, 'the package links wait for a release');
    assert.match(page, /id="release-status" role="status">Coming soon</);
    assert.match(page, /connect-src 'self' https:\/\/api\.github\.com;/);
    assert.match(page, new RegExp(`og:image" content="https://getsidea\\.com/social-${name}\\.jpg"`));
    assert.ok(readFileSync(new URL(`../public/social-${name}.jpg`, import.meta.url)).length > 20000, 'the share image exists');
  }
  const windows = read('../windows/index.html');
  assert.match(windows, /Not yet tried on a Windows PC/);
  assert.match(read('../public/install.sh'), /^#!\/bin\/sh\n/);
  assert.doesNotMatch(read('../src/landing.ts'), /analytics|cookie|localStorage/);
  const vercel = JSON.parse(read('../../vercel.json'));
  assert.equal(vercel.headers.find(rule => rule.source === '/install.sh').headers.find(h => h.key === 'Content-Type').value, 'text/plain; charset=utf-8');
});

import { platformDownloads, visitorPlatform } from '../src/platform.mjs';
test('the home page offers a visitor the Side A their computer runs', () => {
  const chrome = (platform, mobile = false) => ({ userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/140', userAgentData: { platform, mobile } });
  assert.equal(visitorPlatform({ userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0' }), 'windows');
  assert.equal(visitorPlatform(chrome('Windows')), 'windows');
  assert.equal(visitorPlatform({ userAgent: 'Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0' }), 'linux');
  assert.equal(visitorPlatform({ userAgent: 'Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) Chrome/140' }), 'linux');
  assert.equal(visitorPlatform({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Version/26.0 Safari/605.1.15' }), 'mac');
  // Phones and tablets run no daemon: Android says Linux, and gets the Mac page as before.
  assert.equal(visitorPlatform({ userAgent: 'Mozilla/5.0 (Linux; Android 16; Pixel 10) Chrome/140 Mobile Safari/537.36' }), 'mac');
  assert.equal(visitorPlatform({ userAgent: 'Mozilla/5.0 (Linux; Android 16; Tablet) Chrome/140', userAgentData: { platform: 'Android', mobile: false } }), 'mac');
  assert.equal(visitorPlatform({ userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) Mobile/15E148' }), 'mac');
  assert.equal(visitorPlatform({}), 'mac');
  assert.equal(platformDownloads.windows.href, './windows/');
  assert.equal(platformDownloads.linux.other.href, './windows/');
  const home = read('../index.html');
  assert.match(home, /<p class="also" id="also" hidden>/, 'the Mac page is unchanged until a script says otherwise');
});

