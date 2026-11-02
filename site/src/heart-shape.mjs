// A convolution ("blobby") surface: soft kernels strung from each lobe down to the tip, plus one string down the
// middle, summed. A sum of smooth kernels has no creases, the strings swell into one dome across the front, and
// the cleft survives because the field thins between the lobes. Kernels are weighted by their spacing so a string
// reads as one tube rather than a row of beads. The field falls off with |z| alone, so the z = 0 slice is the front
// silhouette. The iOS Love heart is a plump balloon: bowed sides and a fat tip kernel keep its bottom blunt.
export const SHAPE = {
  lobe: { x: 0.5616, y: 0.3697, r: 0.4036, w: 6.3392 },
  tip: { y: -0.7949, r: 0.1724, w: 0.5482 },
  middle: { y: -0.1821, r: 0.4326, w: 0.99 },
  belly: { y: -0.134, r: 0.378, w: 0.68 },
  bow: 0.215,
  taper: 3.2166,
  level: 0.3295,
  depth: 1.18,
  steps: 14,
};
// The surface is found along rays from CENTER, which only works because the heart is star-shaped from there.
const CENTER = [0, -0.1, 0];

function strings({ lobe, tip, middle, belly, bow, taper, steps }) {
  const list = [];
  const add = (x, y, r, step, w) => list.push({ x, y, inv: 1 / (r * r), w: (w * step) / (r * Math.sqrt(Math.PI)) });
  const span = Math.hypot(lobe.x, lobe.y - tip.y) / steps;
  for (const side of [-1, 1]) {
    for (let i = 0; i <= steps; i++) {
      const t = i / steps;
      const r = lobe.r + (tip.r - lobe.r) * Math.pow(t, taper);
      add(side * (lobe.x * (1 - t) + Math.sin(Math.PI * t) * bow), lobe.y + (tip.y - lobe.y) * t, r, span, i === 0 ? lobe.w : i === steps ? tip.w : 1);
    }
  }
  for (let i = 0; i <= steps; i++) {
    const t = i / steps;
    add(0, middle.y + (tip.y - middle.y) * t, middle.r + (tip.r - middle.r) * Math.pow(t, taper), (middle.y - tip.y) / steps, middle.w);
  }
  if (belly) add(0, belly.y, belly.r, 1, belly.w);
  return list;
}

function field(shape) {
  const kernels = strings(shape);
  const level = shape.level;
  const depth2 = 1 / (shape.depth * shape.depth);
  return (x, y, z) => {
    const zz = z * z * depth2;
    let sum = 0, gx = 0, gy = 0, gz = 0;
    for (const k of kernels) {
      const dx = x - k.x, dy = y - k.y;
      const v = k.w * Math.exp(-(dx * dx + dy * dy + zz) * k.inv);
      const e = 2 * v * k.inv;
      sum += v; gx += e * dx; gy += e * dy; gz += e * z * depth2;
    }
    return [level - sum, gx, gy, gz];
  };
}

// Newton along the ray from a nearby guess, falling back to bisection whenever a step leaves the bracket.
function surfaceAlong(sample, dx, dy, dz, guess) {
  let inside = 0, outside = 3, r = guess;
  for (let i = 0; i < 40; i++) {
    const [f, gx, gy, gz] = sample(CENTER[0] + dx * r, CENTER[1] + dy * r, CENTER[2] + dz * r);
    if (Math.abs(f) < 1e-9) break;
    if (f < 0) inside = r; else outside = r;
    const slope = gx * dx + gy * dy + gz * dz;
    let next = slope > 0 ? r - f / slope : NaN;
    if (!(next > inside && next < outside)) next = (inside + outside) / 2;
    if (Math.abs(next - r) < 1e-7) { r = next; break; }
    r = next;
  }
  return r;
}

export function heartMesh(segments = 96, shape = SHAPE) {
  const sample = field(shape);
  const n = segments + 1;
  const faces = [
    (u, v) => [1, v, -u], (u, v) => [-1, v, u],
    (u, v) => [u, 1, -v], (u, v) => [u, -1, v],
    (u, v) => [u, v, 1], (u, v) => [-u, v, -1],
  ];
  const count = faces.length * n * n;
  const positions = new Float32Array(count * 3);
  const normals = new Float32Array(count * 3);
  const index = new Uint32Array(faces.length * segments * segments * 6);
  let p = 0, q = 0;
  faces.forEach((face, f) => {
    let guess = 1;
    for (let j = 0; j < n; j++) {
      for (let i = 0; i < n; i++) {
        const u = Math.tan((i / segments * 2 - 1) * Math.PI / 4), v = Math.tan((j / segments * 2 - 1) * Math.PI / 4);
        let [dx, dy, dz] = face(u, v);
        const l = Math.hypot(dx, dy, dz);
        dx /= l; dy /= l; dz /= l;
        const r = surfaceAlong(sample, dx, dy, dz, guess);
        guess = r;
        const x = CENTER[0] + dx * r, y = CENTER[1] + dy * r, z = CENTER[2] + dz * r;
        const [, gx, gy, gz] = sample(x, y, z);
        const gl = Math.hypot(gx, gy, gz);
        positions[p] = x; positions[p + 1] = y; positions[p + 2] = z;
        normals[p] = gx / gl; normals[p + 1] = gy / gl; normals[p + 2] = gz / gl;
        p += 3;
      }
    }
    const base = f * n * n;
    for (let j = 0; j < segments; j++) {
      for (let i = 0; i < segments; i++) {
        const a = base + j * n + i, b = a + 1, c = a + n, d = c + 1;
        index[q++] = a; index[q++] = b; index[q++] = d;
        index[q++] = a; index[q++] = d; index[q++] = c;
      }
    }
  });
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity, maxZ = 0;
  for (let i = 0; i < positions.length; i += 3) {
    minX = Math.min(minX, positions[i]); maxX = Math.max(maxX, positions[i]);
    minY = Math.min(minY, positions[i + 1]); maxY = Math.max(maxY, positions[i + 1]);
    maxZ = Math.max(maxZ, Math.abs(positions[i + 2]));
  }
  const s = 2 / (maxX - minX);
  for (let i = 0; i < positions.length; i += 3) {
    positions[i] *= s; positions[i + 1] = (positions[i + 1] - minY) * s; positions[i + 2] *= s;
  }
  const outline = (count = 720) => Array.from({ length: count }, (_, i) => {
    const a = (i / count) * 2 * Math.PI, dx = Math.cos(a), dy = Math.sin(a);
    const r = surfaceAlong(sample, dx, dy, 0, 1);
    return [(CENTER[0] + dx * r) * s, (CENTER[1] + dy * r - minY) * s];
  });
  return { positions, normals, index, height: (maxY - minY) * s, depth: 2 * maxZ * s, outline };
}
