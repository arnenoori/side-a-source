export const releasesURL = 'https://github.com/arnenoori/side-a-releases/releases';
export const releaseAPI = 'https://api.github.com/repos/arnenoori/side-a-releases/releases?per_page=30';

export function downloadableRelease(value) {
  if (!value || value.draft || value.prerelease || !value.published_at || !/^v\d+\.\d+\.\d+$/.test(value.tag_name)) return null;
  const version = value.tag_name.slice(1);
  const name = `SideA-${version}-macOS-universal.dmg`;
  const prefix = `${releasesURL}/download/${value.tag_name}/`;
  const asset = value.assets?.find(item => item.name === name && item.state === 'uploaded' && item.browser_download_url === prefix + name && item.size > 0);
  const checksum = value.assets?.find(item => item.name === 'SHA256SUMS.txt' && item.state === 'uploaded' && item.browser_download_url === prefix + 'SHA256SUMS.txt');
  return asset && checksum ? { version, url: asset.browser_download_url, size: asset.size } : null;
}

export function latestDownloadableRelease(releases) {
  return Array.isArray(releases) ? releases.map(downloadableRelease).find(Boolean) ?? null : null;
}

// sidead, the Linux daemon, is its own release (sidead-vX.Y.Z) in the same repository as the Mac app, so a Mac release
// stays the repository's latest. Each package names its architecture; the page links the ones the release really has.
const sideadArchitectures = ['amd64', 'arm64'];

export function sideadRelease(value) {
  if (!value || value.draft || value.prerelease || !value.published_at || !/^sidead-v\d+\.\d+\.\d+$/.test(value.tag_name)) return null;
  const version = value.tag_name.slice('sidead-v'.length);
  const prefix = `${releasesURL}/download/${value.tag_name}/`;
  const find = name => value.assets?.find(item => item.name === name && item.state === 'uploaded' && item.browser_download_url === prefix + name && item.size > 0);
  if (!find('SHA256SUMS.txt')) return null;
  /** @type {Record<string, { tarball: string, deb: string, size: number }>} */
  const packages = {};
  for (const arch of sideadArchitectures) {
    const tarball = find(`side-a-daemon-${version}-linux-${arch}.tar.gz`);
    const deb = find(`side-a-daemon_${version}_${arch}.deb`);
    if (tarball && deb) packages[arch] = { tarball: tarball.browser_download_url, deb: deb.browser_download_url, size: tarball.size };
  }
  return Object.keys(packages).length === sideadArchitectures.length ? { version, packages, checksums: prefix + 'SHA256SUMS.txt' } : null;
}

export function latestSideadRelease(releases) {
  return Array.isArray(releases) ? releases.map(sideadRelease).find(Boolean) ?? null : null;
}
