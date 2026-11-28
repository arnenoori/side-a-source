// Which Side A a visitor's computer can run, from what the browser says about itself. A phone or tablet gets the Mac
// page as before: Android's user agent says Linux and an iPad's says Macintosh, and neither runs a daemon.

/** @typedef {'mac' | 'windows' | 'linux'} Platform */

/**
 * @param {{ userAgent?: string, maxTouchPoints?: number, userAgentData?: { platform?: string, mobile?: boolean } }} navigator
 * @returns {Platform}
 */
export function visitorPlatform(navigator) {
  const hinted = navigator.userAgentData?.platform ?? '';
  const agent = navigator.userAgent ?? '';
  if (navigator.userAgentData?.mobile || /Android|iPhone|iPad|iPod|Mobile/i.test(agent)) return 'mac';
  if (hinted === 'Windows' || /Windows NT/i.test(agent)) return 'windows';
  if (hinted === 'Linux' || hinted === 'Chrome OS' || /Linux|X11|CrOS/i.test(agent)) return 'linux';
  return 'mac';
}

/** What the home page's button offers a visitor who isn't on a Mac, and the other computer it names beside the Mac.
 * @type {Record<Exclude<Platform, 'mac'>, { label: string, href: string, other: { label: string, href: string } }>} */
export const platformDownloads = {
  windows: { label: 'Get Side A for Windows', href: './windows/', other: { label: 'Linux', href: './linux/' } },
  linux: { label: 'Get Side A for Linux', href: './linux/', other: { label: 'Windows', href: './windows/' } },
};
