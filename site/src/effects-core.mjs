// Frame-measured from a 24 fps recording of the iOS Love effect (seconds from the heart's first frame; sizes in
// phone-screen widths): appears 0.00 at 0.12 wide, tip behind the bubble; 0.64 @1.56, 0.89 @3.06, 1.06 @4.06;
// lets go at 4.20 and floats up-left, accelerating; off screen ≈8.40. No beat, no fade. Bubble and veil lead by 0.30.
// The heart is cut flat at a line just above the bubble; its tip starts 0.045 below that line and rises onto it by 0.95.
export const LEAD = 0.3;
export const LET_GO = 4.2;
export const GONE = 8.4;
export const LOVE_DURATION = LEAD + GONE + 0.45;

const GROWTH = [[0, 0.1], [0.06, 0.125], [0.31, 0.218], [0.56, 0.31], [0.81, 0.39], [1.06, 0.48], [1.31, 0.565], [1.56, 0.64], [1.81, 0.69], [2.06, 0.75], [2.56, 0.82], [3.06, 0.89], [3.56, 0.99], [4.06, 1.06], [4.5, 1.1], [6, 1.15], [GONE, 1.2]];
const SINK = [[0, 0.045], [0.25, 0.03], [0.5, 0.022], [0.75, 0.009], [0.95, 0]];
const DRIFT = [[0, 0], [0.8, 0.047], [1.3, 0.08], [1.8, 0.13], [2.3, 0.2], [2.8, 0.27], [3.3, 0.42], [3.8, 0.7], [4.2, 1.1], [4.6, 1.6]];

const clamp = x => Math.min(1, Math.max(0, x));
const easeOut = x => 1 - Math.pow(1 - x, 3);
const easeInOut = x => (x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2);

function track(points, t) {
  if (t <= points[0][0]) return points[0][1];
  const last = points.length - 1;
  if (t >= points[last][0]) return points[last][1];
  let i = 0;
  while (points[i + 1][0] < t) i++;
  const [t1, p1] = points[i], [t2, p2] = points[i + 1];
  const p0 = i > 0 ? points[i - 1][1] : p1, p3 = i + 2 <= last ? points[i + 2][1] : p2;
  const u = (t - t1) / (t2 - t1);
  const m1 = (p2 - p0) / 2, m2 = (p3 - p1) / 2;
  const u2 = u * u, u3 = u2 * u;
  return (2 * u3 - 3 * u2 + 1) * p1 + (u3 - 2 * u2 + u) * m1 + (-2 * u3 + 3 * u2) * p2 + (u3 - u2) * m2;
}

function fill(out, visible, width, sink, drift, yaw, roll, pitch, veil, bubble) {
  out.visible = visible; out.width = width; out.sink = sink; out.drift = drift;
  out.yaw = yaw; out.roll = roll; out.pitch = pitch; out.veil = veil; out.bubble = bubble;
  return out;
}

// Measured on iOS: a one-line bubble is 30 px tall on a screen 330 px wide, so the heart's unit (one phone width)
// is 11 bubble heights. On a desktop that would still overwhelm a footer, so the largest the heart ever gets is
// held to a corner of the window. The growth curve keeps its shape; only its unit changes.
export const PHONE_PER_BUBBLE = 11;
export const HEART_MAX = { viewport: 0.38, px: 420, width: 0.9 };
export const PEAK_WIDTH = GROWTH[GROWTH.length - 1][1];
export function heartUnit(bubbleHeight, width, height) {
  const largest = Math.min(HEART_MAX.viewport * height, HEART_MAX.px, HEART_MAX.width * width);
  return Math.min(PHONE_PER_BUBBLE * bubbleHeight, largest / PEAK_WIDTH);
}

const DEG = Math.PI / 180;
const FLIGHT_LIMITS = { angle: 60 * DEG, curve: 0.22, yaw: 25 * DEG, turn: [0.3, 0.5], spin: 0.12, tilt: 0.3, pitch: 0.18, speed: [0.88, 1.14] };
// The reference's flight: up and to the left at about 46°, no bow, no spin.
export const MEASURED_FLIGHT = { angle: -46 * DEG, curve: 0, yaw: 0, turn: 0.4, spin: 0, tilt: 0, pitch: 0, speed: 1 };

// Each play picks its own way out, so hovering again shows the heart from another side.
export function pickFlight(random = Math.random) {
  const span = ([a, b]) => a + (b - a) * random();
  const around = limit => (2 * random() - 1) * limit;
  const L = FLIGHT_LIMITS;
  const yaw = around(L.yaw);
  return {
    angle: around(L.angle),
    curve: around(L.curve),
    yaw,
    // It turns through facing the viewer, never further round toward edge-on.
    turn: (yaw > 0 || (yaw === 0 && random() < 0.5) ? -1 : 1) * span(L.turn),
    spin: around(L.spin),
    tilt: around(L.tilt),
    pitch: around(L.pitch),
    speed: span(L.speed),
  };
}

export function loveAt(t, flight = MEASURED_FLIGHT, out = {}) {
  if (t <= 0 || t >= LOVE_DURATION) return fill(out, false, 0, 0, 0, 0, 0, 0, 0, 0);
  const veil = easeOut(clamp(t / 0.3)) * (1 - easeInOut(clamp((t - LEAD - GONE) / 0.45)));
  const bubble = easeOut(clamp(t / 0.3)) * (1 - easeInOut(clamp((t - LEAD - GONE + 0.1) / 0.45)));
  const h = t - LEAD;
  if (h < 0 || h >= GONE) return fill(out, false, 0, 0, 0, 0, 0, 0, veil, bubble);
  const width = track(GROWTH, h);
  const away = Math.max(0, h - LET_GO);
  const drift = away > 0 ? track(DRIFT, away) : 0;
  const loose = easeInOut(clamp(away / 2.5));
  // While it grows it stays upright on the bubble and slowly turns, so it reads as solid; once free it leans into its path.
  return fill(out, true, width, Math.max(0, track(SINK, h)), drift,
    flight.yaw + flight.turn * easeInOut(clamp(h / LET_GO)) + 0.04 * Math.sin(h * 1.3) + flight.spin * away * loose,
    0.012 * Math.sin(h * 1.1) + (flight.tilt - 0.3 * flight.angle) * loose,
    0.05 * Math.sin(h * 0.9 + 0.4) + flight.pitch * loose,
    veil, bubble);
}

// Where the heart's tip is in page pixels. The early drift is the measured one; the last stretch lengthens so the
// heart clears this viewport's edge exactly when the reference's heart clears the phone's.
export function heartTip(l, flight, { anchorX, anchorY, phone, width, height }, out = {}) {
  const full = 1.2 * phone;
  const dx = Math.sin(flight.angle), dy = -Math.cos(flight.angle);
  const px = -dy, py = dx;
  const vx = dx + flight.curve * px, vy = dy + flight.curve * py;
  const half = 0.65 * full, below = 0.25 * full, above = 1.1 * full;
  let exit = Infinity;
  if (vy < 0) exit = Math.min(exit, (anchorY + below) / -vy);
  if (vx < 0) exit = Math.min(exit, (anchorX + half) / -vx);
  if (vx > 0) exit = Math.min(exit, (width - anchorX + half) / vx);
  if (vy > 0) exit = Math.min(exit, (height - anchorY + above) / vy);
  const away = exit * 1.04;
  const early = 1.1 * phone * flight.speed;
  const late = Math.pow(clamp((l.drift - 0.08) / (1.1 - 0.08)), 1.3);
  const travel = l.drift * phone * flight.speed + Math.max(0, away - early) * late;
  const bow = flight.curve * away * Math.pow(travel / away, 2);
  out.x = anchorX + dx * travel + px * bow;
  out.y = anchorY + l.sink * phone + dy * travel + py * bow;
  out.away = away;
  return out;
}
