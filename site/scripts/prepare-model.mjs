import { readFile, writeFile, mkdir } from 'node:fs/promises';
import sharp from 'sharp';
import { gzipSync } from 'node:zlib';
const root = new URL('../', import.meta.url);
const meshes = JSON.parse(await readFile(new URL('../Sources/SideA/Resources/discman.json', root), 'utf8'));
const chunks = [];
let byteOffset = 0;
const metadata = meshes.map(({ vertices, normals, indices, ...mesh }) => {
  if (vertices.length !== normals.length || indices.some((index, i) => index !== i)) throw new Error('Unsupported mesh layout');
  const unique = new Map(), positionsList = [], normalsList = [], indexList = [];
  for (let i = 0; i < vertices.length; i += 3) {
    const position = vertices.slice(i, i + 3), normal = normals.slice(i, i + 3);
    const key = [...position, ...normal].join(',');
    let index = unique.get(key);
    if (index === undefined) { index = unique.size; unique.set(key, index); positionsList.push(...position); normalsList.push(...normal); }
    indexList.push(index);
  }
  // Quantized for transfer: 16-bit positions over the mesh bounds (well under 0.1 mm on
  // this model), 16-bit normals and indices. The player expands positions on load.
  const count = positionsList.length / 3;
  const min = [0, 1, 2].map(axis => Math.min(...positionsList.filter((_, i) => i % 3 === axis)));
  const max = [0, 1, 2].map(axis => Math.max(...positionsList.filter((_, i) => i % 3 === axis)));
  const positions = Uint16Array.from(positionsList, (value, i) => { const range = max[i % 3] - min[i % 3]; return range ? Math.round((value - min[i % 3]) / range * 65535) : 0; });
  const normalData = Int16Array.from(normalsList, value => Math.round(Math.max(-1, Math.min(1, value)) * 32767));
  const wide = count > 65535;
  const indexData = wide ? Uint32Array.from(indexList) : Uint16Array.from(indexList);
  const pad = bytes => Buffer.concat([bytes, Buffer.alloc((4 - bytes.length % 4) % 4)]);
  const parts = [pad(Buffer.from(positions.buffer)), pad(Buffer.from(normalData.buffer)), pad(Buffer.from(indexData.buffer))];
  const result = { ...mesh, count, min, max, offset: byteOffset, normalOffset: byteOffset + parts[0].length,
    indexOffset: byteOffset + parts[0].length + parts[1].length, indexCount: indexData.length, wide };
  chunks.push(...parts);
  byteOffset += parts[0].length + parts[1].length + parts[2].length;
  return result;
});
await mkdir(new URL('src/generated/', root), { recursive: true });
await mkdir(new URL('public/', root), { recursive: true });
const compressed = gzipSync(Buffer.concat(chunks), { level: 9 });
await writeFile(new URL('src/generated/discman.mesh', root), compressed);
await writeFile(new URL('src/generated/model.json', root), JSON.stringify(metadata));
const image = new URL('../design/discman.png', root);
await sharp(image.pathname).resize(1200, 630, { fit: 'contain', background: '#f7f8f7' }).flatten({ background: '#f7f8f7' }).jpeg({ quality: 85, mozjpeg: true }).toFile(new URL('public/social.jpg', root).pathname);
console.log(`Prepared ${meshes.length} original Blender meshes (${(compressed.length / 1024).toFixed(0)} KB transfer)`);
