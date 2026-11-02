// Side A Remote's availability, rendered into each page at build time from remote.json: the App Store badge once
// appStoreURL is set, else the public TestFlight beta, else "Coming soon to iPhone" with no link.
export const BADGE = 'remote/app-store-badge.svg';
const PHONE = '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="6.5" y="2.5" width="11" height="19" rx="2.6" /><path d="M10.5 5.2h3" /></svg>';

export function appStoreURL(config) {
  const url = config?.appStoreURL;
  if (url == null) return null;
  if (typeof url !== 'string' || !/^https:\/\/apps\.apple\.com\/[a-z]{2}\/app\/[a-z0-9-]+\/id\d+$/.test(url)) {
    throw new Error(`remote.json: appStoreURL must be an apps.apple.com app link, got ${JSON.stringify(url)}`);
  }
  return url;
}

export function testFlightURL(config) {
  const url = config?.testFlightURL;
  if (url == null) return null;
  if (typeof url !== 'string' || !/^https:\/\/testflight\.apple\.com\/join\/[A-Za-z0-9]+$/.test(url)) {
    throw new Error(`remote.json: testFlightURL must be a testflight.apple.com/join link, got ${JSON.stringify(url)}`);
  }
  return url;
}

// root is the way back to the site's top from the page: './' on the home page, '../' one folder down.
export function availabilityHTML(config, root = './') {
  const url = appStoreURL(config);
  // The beta may not take testers until Beta App Review passes, so the words promise a beta, not instant access.
  const beta = !url && testFlightURL(config);
  if (beta) return `<a class="remote-beta" href="${beta}" data-remote-beta>${PHONE}Join the beta on TestFlight</a>`;
  if (!url) return `<p class="remote-soon">${PHONE}Coming soon to iPhone</p>`;
  return `<a class="remote-store" href="${url}" data-remote-store><img src="${root}${BADGE}" width="120" height="40" alt="Download on the App Store" /></a>`;
}
