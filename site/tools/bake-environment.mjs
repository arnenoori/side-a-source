// Development-only visual tool. Run from site/ and press Bake in the local page.
import { createServer } from 'vite';
import { writeFile } from 'node:fs/promises';
import { gzipSync } from 'node:zlib';
const server = await createServer({
  configFile: false,
  root: new URL('../', import.meta.url).pathname,
  server: { host: '127.0.0.1', port: 4180, strictPort: true },
  plugins: [{
    name: 'save-environment',
    configureServer(server) {
      server.middlewares.use('/save-environment', async (req, res) => {
        if (req.method !== 'POST' || req.headers.origin !== 'http://127.0.0.1:4180') { res.statusCode = 403; res.end(); return; }
        try {
          const chunks = [];
          let length = 0;
          for await (const chunk of req) {
            length += chunk.length;
            if (length > 2_000_000) { res.statusCode = 413; res.end(); return; }
            chunks.push(chunk);
          }
          const bytes = Buffer.concat(chunks);
          const width = Number(req.headers['x-width']), height = Number(req.headers['x-height']);
          if (width !== 336 || height !== 256 || bytes.length !== width * height * 8) { res.statusCode = 400; res.end(); return; }
          await writeFile(new URL('../src/studio.env', import.meta.url), gzipSync(bytes, { level: 9 }));
          await writeFile(new URL('../src/environment.json', import.meta.url), JSON.stringify({ width, height }) + '\n');
          res.end('Saved');
        } catch { res.statusCode = 500; res.end('Bake failed'); }
      });
    },
  }],
});
await server.listen();
console.log('Open http://127.0.0.1:4180/tools/bake-environment.html');
