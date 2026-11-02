// Development-only: turns Side A Remote simulator screenshots into the landing page's phone screens.
// Run from site/: node tools/bake-remote.mjs <name>=<screenshot.png> ...
// Names are the screens in index.html's #remote (sessions, approve, answer, start); the icon comes from design/icon.png.
import sharp from 'sharp';
import { mkdir } from 'node:fs/promises';
const out = new URL('../public/remote/', import.meta.url);
await mkdir(out, { recursive: true });
const write = (image, name) => Promise.all([
  image.clone().avif({ quality: 60, effort: 6 }).toFile(new URL(`${name}.avif`, out).pathname),
  image.clone().webp({ quality: 86, effort: 6 }).toFile(new URL(`${name}.webp`, out).pathname),
]);
// 2x of the largest phone on the page (300 CSS px); every screen shares the iPhone's 1206x2622 shape.
for (const arg of process.argv.slice(2)) {
  const [name, file] = arg.split('=');
  if (!/^[a-z]+$/.test(name) || !file) throw new Error(`Expected name=file.png, got ${arg}`);
  const { width, height } = await sharp(file).metadata();
  if (Math.abs(width / height - 1206 / 2622) > 0.002) throw new Error(`${file} is ${width}x${height}, not an iPhone 17 Pro screenshot`);
  await write(sharp(file).resize({ width: 600 }), name);
  console.log(`${name} <- ${file}`);
}
// The Mac icon's artwork, cropped from its transparent margin, at 2x of 64 px.
await write(sharp(new URL('../../design/icon.png', import.meta.url).pathname).trim().resize({ width: 128 }), 'icon');
