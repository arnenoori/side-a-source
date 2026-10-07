import { test } from 'node:test';
import assert from 'node:assert/strict';
import { downloadableRelease, releasesURL } from '../src/release.mjs';
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
