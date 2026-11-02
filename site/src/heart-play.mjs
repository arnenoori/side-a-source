// State is mutated in place so the frame loop allocates nothing.
export const PLAY = {
  impulse: 9,
  maxSpin: 34,
  friction: 0.9,
  settle: 16,
  settleBelow: [1.5, 5],
  grace: 1.6,
  maxTotal: 30,
  rateSpring: 9,
  click: { px: 4, ms: 320 },
  boing: { spring: 20, damping: 0.3, kick: 2.4, max: 0.22 },
  fling: { gain: 0.5, maxSpeed: 2600, friction: 3 },
};

const clamp01 = x => Math.min(1, Math.max(0, x));
const smoothstep = (a, b, x) => { const u = clamp01((x - a) / (b - a)); return u * u * (3 - 2 * u); };

export function createSpin() {
  return { q: [0, 0, 0, 1], w: [0, 0, 0] };
}

function capSpin(w, max) {
  const m = Math.hypot(w[0], w[1], w[2]);
  if (m > max) { const k = max / m; w[0] *= k; w[1] *= k; w[2] *= k; }
}

export function addSpin(spin, sign = 1) {
  spin.w[1] += (sign < 0 ? -1 : 1) * PLAY.impulse;
  capSpin(spin.w, PLAY.maxSpin);
  return spin;
}

export function setSpin(spin, wx, wy, wz) {
  spin.w[0] = wx; spin.w[1] = wy; spin.w[2] = wz;
  capSpin(spin.w, PLAY.maxSpin);
  return spin;
}

// Premultiplied: the axis is in world space, so a drag turns the heart the way the pointer moves on screen.
export function rotateBy(q, ax, ay, az, angle) {
  const len = Math.hypot(ax, ay, az);
  if (!(len > 0) || angle === 0) return q;
  const s = Math.sin(angle / 2) / len, c = Math.cos(angle / 2);
  const x = ax * s, y = ay * s, z = az * s;
  const qx = q[0], qy = q[1], qz = q[2], qw = q[3];
  q[0] = c * qx + x * qw + y * qz - z * qy;
  q[1] = c * qy - x * qz + y * qw + z * qx;
  q[2] = c * qz + x * qy - y * qx + z * qw;
  q[3] = c * qw - x * qx - y * qy - z * qz;
  const n = Math.hypot(q[0], q[1], q[2], q[3]);
  q[0] /= n; q[1] /= n; q[2] /= n; q[3] /= n;
  return q;
}

export function stepSpin(spin, dt, held = false) {
  const { q, w } = spin;
  if (held) return spin;
  const speed = Math.hypot(w[0], w[1], w[2]);
  const k = PLAY.settle * (1 - smoothstep(PLAY.settleBelow[0], PLAY.settleBelow[1], speed));
  if (q[3] < 0) { q[0] = -q[0]; q[1] = -q[1]; q[2] = -q[2]; q[3] = -q[3]; }
  const v = Math.hypot(q[0], q[1], q[2]);
  const angle = 2 * Math.atan2(v, q[3]);
  const e = v > 1e-9 ? angle / v : 0;
  const c = 2 * Math.sqrt(k);
  const drag = Math.exp(-PLAY.friction * dt);
  for (let i = 0; i < 3; i++) w[i] = (w[i] + dt * (-k * q[i] * e - c * w[i])) * drag;
  const m = Math.hypot(w[0], w[1], w[2]);
  if (m < 1e-4 && angle < 1e-4) { w[0] = w[1] = w[2] = 0; return spin; }
  rotateBy(q, w[0], w[1], w[2], m * dt);
  return spin;
}

export function createBoing() {
  return { x: 0, v: 0 };
}

export function kickBoing(b) {
  b.v -= PLAY.boing.kick;
  return b;
}

export function stepBoing(b, dt) {
  const { spring, damping, max } = PLAY.boing;
  const steps = Math.max(1, Math.ceil(dt / (1 / 120)));
  const h = dt / steps;
  for (let i = 0; i < steps; i++) {
    b.v += h * (-spring * spring * b.x - 2 * damping * spring * b.v);
    b.x += h * b.v;
  }
  if (b.x > max) { b.x = max; b.v = Math.min(0, b.v); }
  if (b.x < -max) { b.x = -max; b.v = Math.max(0, b.v); }
  if (Math.abs(b.x) < 1e-4 && Math.abs(b.v) < 1e-3) b.x = b.v = 0;
  return b;
}

// Paused time is capped at maxTotal minus the timeline's own length, so the effect can never outstay maxTotal.
export function createStory(duration) {
  return { story: 0, real: 0, paused: 0, rate: 1, rateV: 0, held: false, touched: -Infinity, budget: Math.max(0, PLAY.maxTotal - duration) };
}

export function touchStory(c) {
  c.touched = c.real;
  return c;
}

export function stepStory(c, dt) {
  c.real += dt;
  const room = c.budget - c.paused;
  const wantsPause = c.held || c.real - c.touched < PLAY.grace;
  // Leave enough budget for the rate to spring back up, so the cap is never overrun.
  const target = wantsPause && room > 0.4 ? 0 : 1;
  if (room <= 0) { c.rate = 1; c.rateV = 0; } else {
    const k = PLAY.rateSpring;
    c.rateV += dt * (-k * k * (c.rate - target) - 2 * k * c.rateV);
    c.rate = clamp01(c.rate + dt * c.rateV);
    if (c.rate === 0 || c.rate === 1) c.rateV = 0;
  }
  c.story += c.rate * dt;
  c.paused += (1 - c.rate) * dt;
  return c;
}

export function isClick(distancePx, ms) {
  return distancePx <= PLAY.click.px && ms <= PLAY.click.ms;
}

export function createFling() {
  return { x: 0, y: 0, vx: 0, vy: 0 };
}

export function throwFling(f, vx, vy) {
  const speed = Math.hypot(vx, vy);
  const k = speed > PLAY.fling.maxSpeed ? PLAY.fling.maxSpeed / speed : 1;
  f.vx += vx * k * PLAY.fling.gain;
  f.vy += vy * k * PLAY.fling.gain;
  return f;
}

export function stepFling(f, dt) {
  const d = Math.exp(-PLAY.fling.friction * dt);
  f.vx *= d; f.vy *= d;
  f.x += f.vx * dt; f.y += f.vy * dt;
  return f;
}
