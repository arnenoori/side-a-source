import * as THREE from 'three';
import { heartMesh } from './heart-shape.mjs';
import { loveAt, heartTip, heartUnit, pickFlight, LOVE_DURATION } from './effects-core.mjs';
import { addSpin, createBoing, createFling, createSpin, createStory, isClick, kickBoing, rotateBy, setSpin, stepBoing, stepFling, stepSpin, stepStory, throwFling, touchStory } from './heart-play.mjs';

function studio(renderer: THREE.WebGLRenderer) {
  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x121214);
  const disposables: { dispose(): void }[] = [];
  const panel = (w: number, h: number, intensity: number, at: [number, number, number], tint = 0xffffff) => {
    const geometry = new THREE.PlaneGeometry(w, h);
    const material = new THREE.MeshBasicMaterial({ color: new THREE.Color(tint).multiplyScalar(intensity), side: THREE.DoubleSide });
    disposables.push(geometry, material);
    const mesh = new THREE.Mesh(geometry, material);
    mesh.position.set(...at);
    mesh.lookAt(0, 0, 0);
    scene.add(mesh);
    return mesh;
  };
  // Broad, soft, red-tinted lights: the reference's lacquer shows red streaks and a soft sheen, not white windows.
  panel(9, 4, 3.2, [-4.5, 5.5, 7], 0xff5048).rotateZ(-0.5);
  panel(4.4, 3.4, 6.5, [3.8, 3.6, 7.5], 0xff3a30);
  panel(1.2, 9, 11, [7, 0.5, -3.5], 0xff3028);
  panel(0.9, 9, 8, [-7, 0, -3], 0xff3028);
  panel(14, 14, 1.1, [0, 9, 0], 0xffd0cc);
  panel(16, 10, 0.45, [0, 0, 10], 0xffe8e6);
  panel(20, 20, 0.05, [0, -7, 0], 0xf2ece8);
  const pmrem = new THREE.PMREMGenerator(renderer);
  const target = pmrem.fromScene(scene, 0.04);
  pmrem.dispose();
  disposables.forEach(d => d.dispose());
  return target;
}

function heartGeometry(segments: number) {
  const { positions, normals, index, height } = heartMesh(segments);
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
  geometry.setAttribute('normal', new THREE.BufferAttribute(normals, 3));
  geometry.setIndex(new THREE.BufferAttribute(index, 1));
  return { geometry, height };
}

export function createHeartStage(canvas: HTMLCanvasElement) {
  const renderer = new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true, premultipliedAlpha: true, powerPreference: 'high-performance' });
  renderer.setClearColor(0x000000, 0);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.05;
  const environment = studio(renderer);

  const scene = new THREE.Scene();
  scene.environment = environment.texture;

  const { geometry, height } = heartGeometry(matchMedia('(pointer: coarse)').matches ? 64 : 96);
  const material = new THREE.MeshPhysicalMaterial({
    color: new THREE.Color('#82000a'),
    roughness: 0.38,
    metalness: 0,
    clearcoat: 0.45,
    clearcoatRoughness: 0.28,
    specularIntensity: 0.5,
    specularColor: new THREE.Color('#ff3a3a'),
    emissive: new THREE.Color('#4a0006'),
    emissiveIntensity: 0.3,
  });
  material.onBeforeCompile = shader => {
    shader.fragmentShader = shader.fragmentShader
      .replace('#include <emissivemap_fragment>', `#include <emissivemap_fragment>
      float facing = saturate(dot(normal, normalize(vViewPosition)));
      totalEmissiveRadiance += vec3(0.5, 0.0, 0.02) * pow(1.0 - facing, 3.0) + vec3(0.06, 0.0, 0.004) * pow(facing, 3.0);`)
      .replace('#include <opaque_fragment>', `outgoingLight *= mix(0.72, 1.0, smoothstep(-0.55, 0.45, normal.y));
      #include <opaque_fragment>`);
  };
  const mesh = new THREE.Mesh(geometry, material);
  mesh.position.y = -height / 2;
  // Pointer hits test a coarse twin: the rendered mesh has up to 110k triangles, the twin 2k.
  const coarse = heartGeometry(12);
  const proxy = new THREE.Mesh(coarse.geometry, material);
  proxy.position.y = -coarse.height / 2;
  proxy.visible = false;
  const heart = new THREE.Group();
  heart.add(mesh, proxy);
  scene.add(heart);

  const camera = new THREE.PerspectiveCamera(30, 1, 0.1, 80);
  camera.position.z = 12;
  let width = 1, viewportHeight = 1, cut = Infinity;
  const viewHeight = 2 * camera.position.z * Math.tan(THREE.MathUtils.degToRad(camera.fov / 2));
  const raycaster = new THREE.Raycaster();
  const pointer = new THREE.Vector2();
  const hits: THREE.Intersection[] = [];
  const euler = new THREE.Euler();
  const base = new THREE.Quaternion();
  const turned = new THREE.Quaternion();

  return {
    heart,
    size(w: number, h: number) {
      width = w; viewportHeight = h;
      renderer.setPixelRatio(Math.min(devicePixelRatio || 1, 2));
      renderer.setSize(w, h, false);
      camera.aspect = w / h;
      camera.updateProjectionMatrix();
    },
    place(tipX: number, tipY: number, px: number, squash = 0) {
      const perPx = viewHeight / viewportHeight;
      const s = Math.max(1e-3, (px * perPx) / 2);
      heart.scale.set(s * (1 - squash / 2), s * (1 + squash), s * (1 - squash / 2));
      heart.position.set((tipX - width / 2) * perPx, (viewportHeight / 2 - tipY) * perPx + (height / 2) * s, 0);
    },
    pose(q: ArrayLike<number>, pitch: number, yaw: number, roll: number) {
      base.setFromEuler(euler.set(pitch, yaw, roll));
      turned.set(q[0], q[1], q[2], q[3]);
      heart.quaternion.multiplyQuaternions(turned, base);
    },
    cutBelow(y: number) { cut = y; },
    hit(x: number, y: number) {
      if (!heart.visible || y >= cut) return false;
      pointer.set((x / width) * 2 - 1, 1 - (y / viewportHeight) * 2);
      raycaster.setFromCamera(pointer, camera);
      hits.length = 0;
      raycaster.intersectObject(proxy, false, hits);
      return hits.length > 0;
    },
    render() {
      renderer.setScissorTest(false);
      renderer.clear();
      const above = Math.max(0, Math.min(viewportHeight, cut));
      renderer.setScissor(0, viewportHeight - above, width, above);
      renderer.setScissorTest(true);
      renderer.render(scene, camera);
    },
    dispose() {
      geometry.dispose();
      coarse.geometry.dispose();
      material.dispose();
      environment.dispose();
      renderer.dispose();
      renderer.forceContextLoss();
    },
  };
}

// Without text-box trimming the line box is centered, not the caps. A zero-width probe one cap tall, sitting on the
// baseline, reads where this font actually puts its caps, and the text is shifted to center them.
function fitInk(source: HTMLElement) {
  if (CSS.supports('text-box', 'trim-both cap alphabetic')) return;
  const text = source.querySelector<HTMLElement>('.love-text');
  if (!text) return;
  const probe = document.createElement('span');
  probe.style.display = 'inline-block';
  probe.style.width = '0';
  probe.style.height = '1cap';
  text.append(probe);
  const box = text.getBoundingClientRect(), cap = probe.getBoundingClientRect();
  probe.remove();
  const capHeight = cap.height || 0.7 * parseFloat(getComputedStyle(text).fontSize);
  const shift = box.height / 2 - (cap.bottom - box.top - capHeight / 2);
  text.style.setProperty('--ink-shift', `${shift.toFixed(2)}px`);
}

export async function playHeart(source: HTMLElement) {
  const canvas = document.createElement('canvas');
  canvas.className = 'fx-layer';
  canvas.setAttribute('aria-hidden', 'true');
  const stage = createHeartStage(canvas);
  const flight = pickFlight();
  const bubble = source.querySelector<HTMLElement>('.love-bubble') ?? source;
  fitInk(source);

  let width = 0, height = 0, unit = 1;
  const resize = () => {
    width = innerWidth; height = innerHeight;
    stage.size(width, height);
    unit = heartUnit(bubble.offsetHeight || 28, width, height);
  };
  resize();
  addEventListener('resize', resize);

  const veil = document.createElement('div');
  veil.className = 'fx-veil';
  veil.setAttribute('aria-hidden', 'true');
  document.body.append(veil, canvas);
  source.classList.add('loving');

  const love = loveAt(0, flight);
  const tip = { x: 0, y: 0, away: 0 };
  const view = { anchorX: 0, anchorY: 0, phone: 1, width: 0, height: 0 };
  const story = createStory(LOVE_DURATION);
  const spin = createSpin(), boing = createBoing(), fling = createFling();
  const root = document.documentElement;
  let heartX = 0, heartY = 0, heartPx = 0, frameCount = 0;
  let pointerX = -1, pointerY = -1, hover = false, held = false, grabbed = false, played = false;
  let downX = 0, downY = 0, downAt = 0, lastX = 0, lastY = 0, lastAt = 0, wx = 0, wy = 0, vx = 0, vy = 0;

  const near = (x: number, y: number) => Math.hypot(x - heartX, y - (heartY - 0.45 * heartPx)) < 0.75 * heartPx + 8;
  const onHeart = (x: number, y: number) => love.visible && heartPx > 6 && near(x, y) && stage.hit(x, y);
  const cursor = () => {
    root.classList.toggle('heart-grab', hover && !held);
    root.classList.toggle('heart-grabbing', held);
  };
  const swallowClick = (e: Event) => { e.preventDefault(); e.stopPropagation(); };
  const release = (e: PointerEvent | null) => {
    if (!held) return;
    held = false;
    story.held = false;
    touchStory(story);
    if (e) {
      if (isClick(Math.hypot(e.clientX - downX, e.clientY - downY), e.timeStamp - downAt)) {
        addSpin(spin, e.clientX >= heartX ? 1 : -1);
        kickBoing(boing);
      } else if (grabbed && e.timeStamp - lastAt < 90) {
        setSpin(spin, wx, wy, 0);
        throwFling(fling, vx, vy);
      }
      // The press was the heart's, so the click that follows must not reach the page under it.
      addEventListener('click', swallowClick, { capture: true, once: true });
      setTimeout(() => removeEventListener('click', swallowClick, true), 0);
    }
    grabbed = false;
    hover = e?.pointerType === 'mouse' && onHeart(e.clientX, e.clientY);
    cursor();
  };
  const onDown = (e: PointerEvent) => {
    if (e.button !== 0 || !e.isPrimary || !onHeart(e.clientX, e.clientY)) return;
    e.preventDefault();
    e.stopPropagation();
    held = true; grabbed = false; played = true;
    story.held = true;
    downX = lastX = e.clientX; downY = lastY = e.clientY; downAt = lastAt = e.timeStamp;
    wx = wy = vx = vy = 0;
    try { root.setPointerCapture(e.pointerId); } catch { /* capture only keeps the drag when the pointer leaves the window */ }
    cursor();
  };
  const onMove = (e: PointerEvent) => {
    if (!held) {
      if (e.pointerType !== 'mouse') return;
      pointerX = e.clientX; pointerY = e.clientY;
      const now = onHeart(pointerX, pointerY);
      if (now !== hover) { hover = now; cursor(); }
      return;
    }
    if (!e.isPrimary) return;
    pointerX = e.clientX; pointerY = e.clientY;
    e.preventDefault();
    if (!grabbed && Math.hypot(pointerX - downX, pointerY - downY) > 4) {
      grabbed = true;
      setSpin(spin, 0, 0, 0);
    }
    const dx = pointerX - lastX, dy = pointerY - lastY, d = Math.hypot(dx, dy);
    const dt = Math.max(1, e.timeStamp - lastAt) / 1000;
    if (grabbed && d > 0) {
      // A trackball: the point under the pointer follows it over a sphere the heart's size.
      const radius = Math.max(24, heartPx / 2);
      rotateBy(spin.q, dy, dx, 0, d / radius);
      const a = 1 - Math.exp(-dt / 0.05);
      wx += (dy / (radius * dt) - wx) * a;
      wy += (dx / (radius * dt) - wy) * a;
      vx += (dx / dt - vx) * a;
      vy += (dy / dt - vy) * a;
    }
    lastX = pointerX; lastY = pointerY; lastAt = e.timeStamp;
  };
  const onUp = (e: PointerEvent) => {
    if (!held || !e.isPrimary) return;
    e.preventDefault();
    e.stopPropagation();
    release(e);
  };
  const onCancel = () => release(null);
  const onOut = () => { pointerX = pointerY = -1; if (hover) { hover = false; cursor(); } };
  // Scrolling is decided at touchstart, so a touch that lands on the heart must be claimed there; one that misses
  // is left alone and scrolls the page as usual.
  const onTouch = (e: TouchEvent) => {
    const t = e.touches[0];
    if (e.touches.length === 1 && t && onHeart(t.clientX, t.clientY)) e.preventDefault();
  };
  const onHidden = () => { if (document.hidden) release(null); };
  addEventListener('touchstart', onTouch, { capture: true, passive: false });
  addEventListener('pointerdown', onDown, true);
  addEventListener('pointermove', onMove, true);
  addEventListener('pointerup', onUp, true);
  addEventListener('pointercancel', onCancel, true);
  addEventListener('blur', onCancel);
  root.addEventListener('pointerleave', onOut);
  document.addEventListener('visibilitychange', onHidden);

  try {
    await new Promise<void>(resolve => {
      let last = performance.now();
      const frame = (now: number) => {
        const dt = Math.min(0.05, Math.max(0, (now - last) / 1000));
        last = now;
        stepStory(story, dt);
        stepSpin(spin, dt, grabbed);
        stepBoing(boing, dt);
        stepFling(fling, dt);
        const l = loveAt(story.story, flight, love);
        source.style.setProperty('--love', l.bubble.toFixed(3));
        veil.style.opacity = l.veil.toFixed(3);
        const b = bubble.getBoundingClientRect();
        // Measured on iOS: the cut sits a tenth of the bubble's height above it, and the heart rises from about 1.8
        // bubble heights in from the bubble's leading edge, not its middle.
        const cut = b.top - 0.1 * b.height;
        view.anchorX = b.left + Math.min(b.width / 2, 1.8 * b.height) + fling.x;
        view.anchorY = cut + fling.y;
        view.phone = unit; view.width = width; view.height = height;
        heartTip(l, flight, view, tip);
        heartPx = l.width * unit;
        // Held, it bobs, and only upward, so its tip never dips behind the bubble.
        const bob = 0.5 * (1 - Math.cos(story.real * 2.4)) * Math.min(8, 0.03 * heartPx) * (1 - story.rate);
        heartX = tip.x; heartY = tip.y - bob;
        stage.heart.visible = l.visible;
        // Once played with it can be swung and thrown anywhere, so it is no longer cut off at the bubble's top.
        stage.cutBelow(played && l.sink === 0 ? Infinity : cut);
        stage.place(heartX, heartY, heartPx, boing.x);
        stage.pose(spin.q, l.pitch, l.yaw, l.roll);
        stage.render();
        if (!held && pointerX >= 0 && ++frameCount % 6 === 0) {
          const now = onHeart(pointerX, pointerY);
          if (now !== hover) { hover = now; cursor(); }
        }
        if (story.story < LOVE_DURATION) requestAnimationFrame(frame);
        else resolve();
      };
      requestAnimationFrame(frame);
    });
  } finally {
    removeEventListener('resize', resize);
    removeEventListener('touchstart', onTouch, true);
    removeEventListener('pointerdown', onDown, true);
    removeEventListener('pointermove', onMove, true);
    removeEventListener('pointerup', onUp, true);
    removeEventListener('pointercancel', onCancel, true);
    removeEventListener('blur', onCancel);
    root.removeEventListener('pointerleave', onOut);
    document.removeEventListener('visibilitychange', onHidden);
    root.classList.remove('heart-grab', 'heart-grabbing');
    source.classList.remove('loving');
    source.style.removeProperty('--love');
    canvas.remove();
    veil.remove();
    stage.dispose();
  }
}
