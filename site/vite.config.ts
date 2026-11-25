import { defineConfig } from 'vite';
import { existsSync, readFileSync } from 'node:fs';
import { BADGE, appStoreURL, availabilityHTML } from './src/remote-availability.mjs';
const remoteAvailability = {
  name: 'remote-availability',
  transformIndexHtml(html: string, ctx: { path: string }) {
    if (!html.includes('<!-- remote-availability -->')) return html;
    const config = JSON.parse(readFileSync(new URL('./src/remote.json', import.meta.url), 'utf8'));
    if (appStoreURL(config) && !existsSync(new URL(`./public/${BADGE}`, import.meta.url))) {
      throw new Error(`Add Apple's official badge at public/${BADGE} before setting appStoreURL`);
    }
    const root = '../'.repeat(ctx.path.split('/').length - 2) || './';
    return html.replaceAll('<!-- remote-availability -->', availabilityHTML(config, root));
  },
};
export default defineConfig({
  base: './',
  // Several pages, so an unknown path is a 404 rather than the home page (/pair must never load the home page's scripts).
  appType: 'mpa',
  plugins: [remoteAvailability],
  build: {
    modulePreload: { polyfill: false },
    rollupOptions: {
      input: { main: 'index.html', 'how-redirect': 'how/index.html', privacy: 'privacy/index.html', remote: 'remote/index.html', pair: 'pair/index.html', linux: 'linux/index.html', windows: 'windows/index.html' },
    },
  },
});
