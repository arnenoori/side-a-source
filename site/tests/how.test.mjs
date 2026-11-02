import test from 'node:test';
import assert from 'node:assert/strict';
import { createLinger, createPress } from '../src/linger.mjs';
import { loveAt, heartTip, heartUnit, pickFlight, MEASURED_FLIGHT, LEAD, LET_GO, GONE, LOVE_DURATION, PEAK_WIDTH, PHONE_PER_BUBBLE } from '../src/effects-core.mjs';
import { PLAY, addSpin, createBoing, createSpin, createStory, isClick, kickBoing, rotateBy, stepBoing, stepSpin, stepStory, touchStory, createFling, throwFling, stepFling } from '../src/heart-play.mjs';
import { heartMesh } from '../src/heart-shape.mjs';
import { readFileSync } from 'node:fs';
import { formatMemory, memoryWarning, islandShortcut, macSleeps } from '../src/demo-core.mjs';

function clock() {
  let now = 0, next = 1;
  const timers = new Map();
  return {
    schedule: (run, ms) => { const id = next++; timers.set(id, { at: now + ms, run }); return id; },
    cancel: id => timers.delete(id),
    advance(ms) {
      now += ms;
      for (const [id, t] of [...timers]) if (t.at <= now) { timers.delete(id); t.run(); }
    },
  };
}

test('linger fires once after resting, not before', () => {
  const c = clock();
  let fired = 0;
  const l = createLinger({ delay: 4500, onFire: () => fired++, schedule: c.schedule, cancel: c.cancel });
  l.enter(10, 10);
  c.advance(4400);
  assert.equal(fired, 0);
  c.advance(100);
  assert.equal(fired, 1);
  l.move(20, 20);
  c.advance(10000);
  assert.equal(fired, 1, 'once per hover');
});

test('leaving cancels the wait and re-arms the next hover', () => {
  const c = clock();
  let fired = 0;
  const l = createLinger({ delay: 1000, onFire: () => fired++, schedule: c.schedule, cancel: c.cancel });
  l.enter(0, 0);
  c.advance(900);
  l.leave();
  c.advance(5000);
  assert.equal(fired, 0);
  l.enter(0, 0);
  c.advance(1000);
  assert.equal(fired, 1);
  l.leave();
  l.enter(0, 0);
  c.advance(1000);
  assert.equal(fired, 2);
});

test('the love heart follows the measured iMessage timeline', () => {
  const at = h => loveAt(LEAD + h);
  assert.equal(loveAt(0).visible, false);
  assert.equal(loveAt(LEAD - 0.01).visible, false, 'the bubble goes first');
  assert.ok(loveAt(LEAD - 0.01).bubble > 0.9 && loveAt(LEAD - 0.01).veil > 0.9);
  const near = (a, b, tol, label) => assert.ok(Math.abs(a - b) <= tol, `${label}: ${a.toFixed(3)} vs ${b}`);
  near(at(0.06).width, 0.125, 0.005, 'appears small');
  near(at(1.56).width, 0.64, 0.005, 'inflates fast');
  near(at(3.06).width, 0.89, 0.005, 'then slows');
  near(at(4.06).width, 1.06, 0.005, 'nearly full');
  for (let h = 0.05; h < GONE; h += 0.05) assert.ok(at(h).width >= at(h - 0.05).width - 1e-9, 'never deflates');
  assert.equal(at(LET_GO - 0.01).drift, 0, 'tied to the bubble until it lets go');
  assert.ok(at(LET_GO + 1).drift > 0 && at(LET_GO + 3).drift > 3 * at(LET_GO + 1).drift, 'floats away, accelerating');
  assert.equal(at(GONE + 0.01).visible, false);
  assert.ok(loveAt(LOVE_DURATION - 0.01).veil < 0.01 && loveAt(LOVE_DURATION - 0.01).bubble < 0.01, 'settles back');
  assert.equal(loveAt(LOVE_DURATION + 1).veil, 0);
});

function seeded(seed) {
  return () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 2 ** 32; };
}

test('like iOS, the heart rises from behind the bubble: tip hidden at first, resting on the cut by about a second', () => {
  const at = h => loveAt(LEAD + h);
  assert.ok(at(0.02).sink > 0.04 && at(0.02).sink < 0.05, `starts hidden: ${at(0.02).sink}`);
  for (let h = 0.05; h < LET_GO; h += 0.05) assert.ok(at(h).sink <= at(h - 0.05).sink + 1e-9 && at(h).sink >= 0, 'only rises, never pokes below or past the cut');
  assert.equal(at(0.96).sink, 0, 'tip on the cut');
  assert.equal(at(LET_GO - 0.01).sink, 0);
  const view = { anchorX: 300, anchorY: 700, phone: 400, width: 1280, height: 800 };
  assert.ok(heartTip(at(0.1), MEASURED_FLIGHT, view).y > view.anchorY + 10, 'tip starts below the cut line, hidden behind the bubble');
  // The visible part is what clears the cut: a sliver of the lobes first, the whole heart by about a second.
  const visible = h => { const l = at(h); return Math.max(0, l.width / 1.13 - l.sink) / (l.width / 1.13); };
  assert.ok(visible(0.1) < 0.7 && visible(0.5) > 0.8 && visible(1) === 1, `${visible(0.1)} ${visible(0.5)}`);
});

test('the heart grows on its anchor, turns, and always clears the screen', () => {
  const at = (h, f) => loveAt(LEAD + h, f);
  for (const [width, height] of [[1280, 800], [1440, 900], [1920, 1080], [390, 844], [375, 667], [430, 932]]) {
    const phone = heartUnit(28, width, height);
    for (let i = 0; i < 200; i++) {
      const f = pickFlight(seeded(i * 7 + width));
      const view = { anchorX: width / 2 + (i % 5) * 20, anchorY: height - 60, phone, width, height };
      for (const h of [0.1, 1, 2.5, LET_GO - 0.01]) {
        const tip = heartTip(at(h, f), f, view);
        assert.equal(tip.x, view.anchorX, 'on its anchor while it grows');
        assert.equal(tip.y, view.anchorY + at(h, f).sink * phone);
        assert.ok(Math.abs(at(h, f).roll) < 0.02, 'upright while it grows');
      }
      assert.ok(Math.abs(at(LET_GO - 0.01, f).yaw - at(0.01, f).yaw) > 0.2, 'turns while it grows');
      for (let h = 0; h < GONE; h += 0.1) assert.ok(Math.abs(at(h, f).yaw) < (60 * Math.PI) / 180, 'never turns edge-on');
      const last = at(GONE - 0.005, f);
      const tip = heartTip(last, f, view);
      const size = last.width * phone;
      const off = tip.x + 0.6 * size < 0 || tip.x - 0.6 * size > width || tip.y + 0.2 * size < 0;
      assert.ok(off, `off screen by the end (${width}×${height}, flight ${i}: ${tip.x.toFixed(0)}, ${tip.y.toFixed(0)})`);
      const mid = heartTip(at(LET_GO + 2, f), f, view);
      assert.ok(mid.y < view.anchorY, 'floats up');
      assert.ok(Math.abs(Math.atan2(mid.x - view.anchorX, view.anchorY - mid.y)) < (75 * Math.PI) / 180, 'within the cone above the bubble');
    }
  }
  assert.equal(heartTip(at(1, MEASURED_FLIGHT), MEASURED_FLIGHT, { anchorX: 500, anchorY: 700, phone: 400, width: 1280, height: 800 }).x, 500);
  const flights = [pickFlight(() => 0), pickFlight(() => 0.999999), ...Array.from({ length: 500 }, (_, i) => pickFlight(seeded(i + 1)))];
  for (const f of flights) assert.ok(Math.abs(f.angle) <= Math.PI / 3 + 1e-9, `angle ${f.angle}`);
  const angles = flights.map(f => f.angle);
  assert.ok(Math.min(...angles) < -0.8 && Math.max(...angles) > 0.8, 'goes both ways');
  assert.notDeepEqual(pickFlight(seeded(1)), pickFlight(seeded(2)), 'plays differ');
});

test('the heart is plump like the iOS Love heart: wide, deep, a shallow cleft and a blunt tip', () => {
  const { height, depth, outline } = heartMesh(32);
  const width = 2;
  assert.ok(width / height >= 1.1 && width / height <= 1.15, `width/height ${(width / height).toFixed(3)}`);
  assert.ok(depth / width >= 0.55 && depth / width <= 0.6, `depth/width ${(depth / width).toFixed(3)}`);
  const pts = outline(1440);
  // Circle through the tip (center on the axis) fit to the outline's bottom: x² + y² = 2ry.
  let num = 0, den = 0;
  for (const [x, y] of pts) if (y > 1e-4 && y < 0.12) { num += (x * x + y * y) * y; den += 2 * y * y; }
  const tipRadius = num / den;
  assert.ok(tipRadius > 0.3, `blunt tip: radius ${tipRadius.toFixed(3)} of a half-width 1 (the old, pointed heart was 0.21)`);
  const top = Math.max(...pts.map(p => p[1]));
  const cleftY = Math.max(...pts.filter(p => Math.abs(p[0]) < 0.02).map(p => p[1]));
  const cleft = (top - cleftY) / width;
  assert.ok(cleft > 0.1 && cleft < 0.16, `shallow cleft: ${cleft.toFixed(3)} of the width (iOS: 0.12–0.15)`);
  const widest = pts.reduce((a, p) => (Math.abs(p[0]) > Math.abs(a[0]) ? p : a));
  assert.ok(widest[1] / height > 0.6, 'round shoulders high up, not a V');
  const halfAt = f => Math.max(...pts.filter(p => Math.abs(p[1] - f * height) < 0.01).map(p => Math.abs(p[0])));
  assert.ok(halfAt(0.3) > 0.7 && halfAt(0.15) > 0.45, `sides bulge: ${halfAt(0.3).toFixed(2)}, ${halfAt(0.15).toFixed(2)}`);
});

test('the heart is one smooth, symmetric, closed shape', () => {
  const { positions, normals, index, height } = heartMesh(32);
  let minX = Infinity, maxX = -Infinity, minY = Infinity, cy = 0;
  const n = positions.length / 3;
  for (let i = 0; i < positions.length; i += 3) {
    minX = Math.min(minX, positions[i]); maxX = Math.max(maxX, positions[i]); minY = Math.min(minY, positions[i + 1]); cy += positions[i + 1] / n;
  }
  assert.ok(Math.abs(maxX - minX - 2) < 1e-5 && Math.abs(minX + 1) < 1e-3, 'two wide, centered');
  assert.ok(Math.abs(minY) < 1e-6, 'tip at the origin');
  for (let i = 0; i < positions.length; i += 3) {
    const l = Math.hypot(normals[i], normals[i + 1], normals[i + 2]);
    assert.ok(Math.abs(l - 1) < 1e-5, 'unit normals');
    assert.ok(positions[i] * normals[i] + (positions[i + 1] - cy) * normals[i + 1] + positions[i + 2] * normals[i + 2] > 0, 'normals face out');
  }
  // Mirror symmetry: the field is even in x, so the mesh's right half mirrors its left.
  const key = (x, y, z) => `${x.toFixed(3)},${y.toFixed(3)},${z.toFixed(3)}`;
  const set = new Set();
  for (let i = 0; i < positions.length; i += 3) set.add(key(positions[i], positions[i + 1], positions[i + 2]));
  let mirrored = 0;
  for (let i = 0; i < positions.length; i += 3) if (set.has(key(-positions[i], positions[i + 1], positions[i + 2]))) mirrored++;
  assert.ok(mirrored / n > 0.98, `symmetric (${mirrored}/${n})`);
  assert.equal(index.length % 3, 0);
});

test('memory reads like the app', () => {
  assert.equal(formatMemory(860), '860 MB');
  assert.equal(formatMemory(3277), '3.2 GB');
  assert.equal(memoryWarning(14131), 'Sessions hold 14 GB · memory is tight');
  assert.equal(memoryWarning(6861), null);
});

test('island shortcuts need control and option, and match the open card', () => {
  const key = (code, mods = {}) => ({ code, key: 'x', ctrlKey: true, altKey: true, metaKey: false, ...mods });
  assert.equal(islandShortcut('ask', key('KeyY')), 'allow');
  assert.equal(islandShortcut('ask', key('KeyN')), 'deny');
  assert.equal(islandShortcut('ask', key('KeyY', { altKey: false })), null);
  assert.equal(islandShortcut('ask', key('KeyY', { metaKey: true })), null);
  assert.equal(islandShortcut('done', key('KeyR')), 'reply');
  assert.equal(islandShortcut('done', key('KeyY')), null);
  assert.equal(islandShortcut('rest', key('KeyY')), null);
  assert.equal(islandShortcut('ask', { code: 'Escape', key: 'Escape' }), 'collapse');
});

test('the one page carries one love egg, in its footer', () => {
  const page = readFileSync(new URL('../index.html', import.meta.url), 'utf8');
  assert.match(page, /<footer><a [^>]*data-love-egg[^>]*>Made with love by Arne Noori<\/a>/);
  assert.equal(page.match(/data-love-egg/g).length, 1, 'one credit');
});

test('the heart is sized from the bubble, as on iOS, and held to a corner of a large window', () => {
  // Fully inflated, the iOS heart is about 1.2 phone widths, 13 bubble heights.
  assert.equal(heartUnit(28, 5000, 5000), PHONE_PER_BUBBLE * 28, 'a roomy window keeps the measured ratio');
  for (const [w, h] of [[1280, 800], [1920, 1080], [2560, 1440], [390, 844], [375, 667], [430, 932]]) {
    const peak = heartUnit(28, w, h) * PEAK_WIDTH;
    assert.ok(peak <= 0.38 * h + 1e-9 && peak <= 420 + 1e-9 && peak <= 0.9 * w + 1e-9, `${w}×${h}: ${peak.toFixed(0)} px`);
    assert.ok(peak > 150, `${w}×${h}: still a moment, ${peak.toFixed(0)} px`);
  }
  assert.ok(heartUnit(28, 1280, 800) * PEAK_WIDTH <= 304, 'about a third of a laptop screen, not a takeover');
  assert.ok(heartUnit(14, 1920, 1080) < heartUnit(28, 1920, 1080), 'follows the bubble');
});

test('clicks spin the heart, faster with each, to a cap, and the spin dies down', () => {
  const spin = createSpin();
  addSpin(spin, 1);
  assert.equal(spin.w[1], PLAY.impulse);
  addSpin(spin, 1);
  assert.equal(spin.w[1], 2 * PLAY.impulse, 'rapid clicks accumulate');
  for (let i = 0; i < 20; i++) addSpin(spin, 1);
  assert.equal(spin.w[1], PLAY.maxSpin, 'capped');
  addSpin(spin, -1);
  assert.equal(spin.w[1], PLAY.maxSpin - PLAY.impulse, 'a click on the other side brakes it');
  const s = createSpin();
  addSpin(s, 1);
  let turned = 0, last = 0;
  for (let i = 0; i < 60 * 8; i++) {
    const before = s.w[1];
    stepSpin(s, 1 / 60);
    assert.ok(Math.abs(s.w[1]) <= Math.abs(before) + 1e-9 || Math.abs(s.w[1]) < 1, 'never speeds up by itself');
    turned += Math.abs(before) / 60;
    if (i === 59) last = Math.abs(s.w[1]);
  }
  assert.ok(last < PLAY.impulse && last > 0.2 * PLAY.impulse, `coasts: ${last.toFixed(2)} rad/s after a second`);
  assert.ok(turned > Math.PI, `a click is worth more than half a turn (${(turned / (2 * Math.PI)).toFixed(2)} turns)`);
  assert.ok(Math.hypot(...s.w) < 1e-3 && Math.abs(s.q[3]) > 0.9999, 'comes to rest upright');
});

test('a dragged heart turns like a trackball and settles upright, critically damped', () => {
  const s = createSpin();
  rotateBy(s.q, 1, 0, 0, 1.2);
  assert.ok(Math.abs(s.q[0] - Math.sin(0.6)) < 1e-9 && Math.abs(s.q[3] - Math.cos(0.6)) < 1e-9);
  let overshoot = false;
  for (let i = 0; i < 60 * 4; i++) {
    stepSpin(s, 1 / 60);
    if (s.q[0] < -1e-3) overshoot = true;
  }
  assert.ok(!overshoot, 'no wobble past upright');
  assert.ok(Math.abs(s.q[3]) > 0.9999, 'upright again');
  const held = createSpin();
  rotateBy(held.q, 0, 1, 0, 1);
  const q = [...held.q];
  stepSpin(held, 0.1, true);
  assert.deepEqual(held.q, q, 'held still while grabbed');
});

test('a click squashes the heart and it boings back', () => {
  const b = createBoing();
  kickBoing(b);
  let min = 0, max = 0;
  for (let i = 0; i < 120; i++) { stepBoing(b, 1 / 60); min = Math.min(min, b.x); max = Math.max(max, b.x); }
  assert.ok(min < -0.05 && min >= -PLAY.boing.max, `squashes: ${min.toFixed(3)}`);
  assert.ok(max > 0.01, 'stretches on the rebound');
  assert.equal(b.x, 0, 'settles');
  assert.ok(isClick(2, 150) && !isClick(12, 150) && !isClick(2, 600));
});

test('holding the heart pauses its story; the pause is capped so the effect ends within 30 s', () => {
  const untouched = createStory(LOVE_DURATION);
  while (untouched.story < LOVE_DURATION) stepStory(untouched, 1 / 60);
  assert.ok(Math.abs(untouched.real - LOVE_DURATION) < 0.02, 'untouched, the timing is unchanged');

  const c = createStory(LOVE_DURATION);
  for (let i = 0; i < 120; i++) stepStory(c, 1 / 60);
  const at = c.story;
  c.held = true;
  for (let i = 0; i < 60 * 3; i++) stepStory(c, 1 / 60);
  assert.ok(c.story - at < 0.3, `held, it floats in place (${(c.story - at).toFixed(2)} s of story in 3 s)`);
  c.held = false;
  touchStory(c);
  const released = c.story;
  for (let i = 0; i < 60 * PLAY.grace * 0.8; i++) stepStory(c, 1 / 60);
  assert.ok(c.story - released < 0.15, 'lingers a moment after the last touch');
  for (let i = 0; i < 60 * 3; i++) stepStory(c, 1 / 60);
  assert.ok(c.rate > 0.99, 'then floats on');

  const forever = createStory(LOVE_DURATION);
  forever.held = true;
  let steps = 0;
  while (forever.story < LOVE_DURATION && steps++ < 60 * 60) stepStory(forever, 1 / 60);
  assert.ok(forever.real <= PLAY.maxTotal + 1e-6, `held forever, it still ends by ${PLAY.maxTotal} s (${forever.real.toFixed(2)})`);
  assert.ok(forever.real > PLAY.maxTotal - 1, 'and uses the extension');
  let prev = -1;
  const smooth = createStory(LOVE_DURATION);
  for (let i = 0; i < 600; i++) {
    smooth.held = i > 60 && i < 300;
    stepStory(smooth, 1 / 60);
    if (prev >= 0) assert.ok(Math.abs(smooth.rate - prev) < 0.2, 'the clock eases to a stop and back, no jumps');
    prev = smooth.rate;
  }
});

test('a flick throws the heart its way, capped, and the throw coasts out', () => {
  const f = createFling();
  throwFling(f, 100000, 0);
  assert.ok(Math.abs(f.vx - PLAY.fling.maxSpeed * PLAY.fling.gain) < 1e-9 && f.vy === 0);
  for (let i = 0; i < 60 * 3; i++) stepFling(f, 1 / 60);
  assert.ok(f.x > 300 && f.x < PLAY.fling.maxSpeed * PLAY.fling.gain / PLAY.fling.friction + 1, `travels ${f.x.toFixed(0)} px`);
  assert.ok(Math.abs(f.vx) < 2, 'and stops');
});

test('on touch, a long press fires like iMessage; a scroll or an early lift cancels it', () => {
  const c = clock();
  const log = [];
  const p = createPress({ delay: 700, slop: 10, onStart: () => log.push('start'), onCancel: () => log.push('cancel'), onFire: () => log.push('fire'), schedule: c.schedule, cancel: c.cancel });
  p.down(0, 0); c.advance(400); p.up(); c.advance(1000);
  assert.deepEqual(log, ['start', 'cancel'], 'lifted early');
  p.down(0, 0); p.move(0, 14); c.advance(1000);
  assert.deepEqual(log.slice(2), ['start', 'cancel'], 'a scroll is not a press');
  p.down(0, 0); p.move(3, 4); c.advance(699);
  assert.deepEqual(log.slice(4), ['start'], 'a small wobble keeps the press');
  c.advance(1);
  assert.deepEqual(log.slice(4), ['start', 'fire']);
  p.up();
  assert.equal(p.consume(), true, 'the lift that follows is the egg\'s');
  assert.equal(p.consume(), false);
});

test('How it works lives on the home page; /how/ forwards to it', () => {
  const read = path => readFileSync(new URL(path, import.meta.url), 'utf8');
  const page = read('../index.html');
  for (const id of ['how', 'switch', 'island', 'background', 'overnight', 'remote']) assert.match(page, new RegExp(`id="${id}"`), id);
  assert.match(page, /<nav>.*<a class="icon-link" href="https:\/\/github.com\/arnenoori\/side-a-source" aria-label="Side A on GitHub"/);
  assert.match(page, /<footer>.*Security details.*data-dialog="privacy"/);
  assert.doesNotMatch(page, /href="[^"]*\/how\/"|data-open="setup"/, 'no links to the old page or the removed Setup dialog');
  assert.equal(page.match(/<h1[ >]/g).length, 1, 'one h1');
  const ids = [...page.matchAll(/ id="([^"]+)"/g)].map(m => m[1]);
  assert.equal(new Set(ids).size, ids.length, 'ids stay unique after the merge');
  const redirect = read('../how/index.html');
  assert.match(redirect, /http-equiv="refresh" content="0; url=\.\.\/#how"/);
  assert.match(redirect, /rel="canonical" href="https:\/\/getsidea\.com\/"/);
  assert.doesNotMatch(read('../public/sitemap.xml'), /\/how\//);
});

test('keep awake follows the app: agents hold the Mac up, the lid needs both options, sleep returns after the grace', () => {
  const grace = 1000;
  const sleeps = (o = {}) => macSleeps({ keepAwake: true, lidOption: true, lidClosed: false, working: true, idleMs: 0, ...o }, grace);
  assert.equal(sleeps(), false, 'awake while an agent works');
  assert.equal(sleeps({ lidClosed: true }), false, 'and with the lid closed when allowed');
  assert.equal(sleeps({ lidClosed: true, lidOption: false }), true, 'a closed lid sleeps without the lid option');
  assert.equal(sleeps({ lidClosed: true, keepAwake: false }), true, 'or with keep awake off');
  assert.equal(sleeps({ working: false, idleMs: grace - 1 }), false, 'waits out the grace');
  assert.equal(sleeps({ working: false, idleMs: grace, lidClosed: true }), true, 'then sleeps, lid open or closed');
});
