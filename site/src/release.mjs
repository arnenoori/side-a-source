export const releasesURL = 'https://github.com/arnenoori/side-a-releases/releases';
export const releaseAPI = 'https://api.github.com/repos/arnenoori/side-a-releases/releases?per_page=10';

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
