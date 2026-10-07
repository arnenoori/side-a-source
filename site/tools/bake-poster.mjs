// Development-only: renders the landing-page poster from the live Three.js scene.
// Run from site/ with Chrome installed: node tools/bake-poster.mjs
import { createServer } from 'vite';
import { spawn } from 'node:child_process';
import sharp from 'sharp';
const out = new URL('../public/', import.meta.url);
let done;
const saved = new Promise(resolve => { done = resolve; });
const server = await createServer({
  configFile: false,
  root: new URL('../', import.meta.url).pathname,
  server: { host: '127.0.0.1', port: 4181, strictPort: true },
  plugins: [{
    name: 'save-poster',
    configureServer(server) {
      server.middlewares.use('/save-poster', async (req, res) => {
        if (req.method !== 'POST') { res.statusCode = 405; res.end(); return; }
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const width = Number(req.headers['x-width']), height = Number(req.headers['x-height']);
        const source = sharp(Buffer.concat(chunks));
        // 2x for the largest stage, 1x for small screens; rendered at 4x and downsampled.
        for (const [scale, name] of [[2, 'poster'], [1, 'poster-small']]) {
          const size = { width: width * scale, height: height * scale };
          await source.clone().resize(size).avif({ quality: 62, effort: 4 }).toFile(new URL(`${name}.avif`, out).pathname);
          await source.clone().resize(size).webp({ quality: 88, alphaQuality: 90, effort: 6 }).toFile(new URL(`${name}.webp`, out).pathname);
        }
        res.end('ok');
        done({ width, height });
      });
    },
  }],
});
await server.listen();
// A plain headless launch on macOS never ticks requestAnimationFrame; a DevTools-driven page does.
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', ['--headless=new', '--no-first-run',
  '--remote-debugging-port=9336', `--user-data-dir=${new URL('../node_modules/.cache/poster-chrome', import.meta.url).pathname}`,
  'about:blank'], { stdio: 'ignore' });
let page;
for (let i = 0; i < 100 && !page; i++) {
  try { page = (await (await fetch('http://127.0.0.1:9336/json/list')).json()).find(target => target.type === 'page'); }
  catch { await new Promise(resolve => setTimeout(resolve, 100)); }
}
const socket = new WebSocket(page.webSocketDebuggerUrl);
await new Promise(resolve => socket.addEventListener('open', resolve));
socket.send(JSON.stringify({ id: 1, method: 'Page.navigate', params: { url: 'http://127.0.0.1:4181/tools/bake-poster.html' } }));
const timeout = setTimeout(() => { console.error('Bake timed out'); chrome.kill(); process.exit(1); }, 180000);
const { width, height } = await saved;
clearTimeout(timeout);
socket.close();
chrome.kill();
await server.close();
console.log(`Poster baked at ${width}x${height} CSS px (2x and 1x, AVIF and WebP)`);
