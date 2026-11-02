export function createLinger({ delay = 4500, onFire, schedule = setTimeout, cancel = clearTimeout }) {
  let timer = null;
  let fired = false;

  const stop = () => { if (timer !== null) cancel(timer); timer = null; };
  const arm = () => {
    stop();
    timer = schedule(() => { timer = null; fired = true; onFire(); }, delay);
  };

  return {
    enter() { if (!fired) arm(); },
    move() { if (!fired && timer === null) arm(); },
    leave() { stop(); fired = false; },
  };
}

// iMessage's own gesture: a long press on Send. Moving past `slop` means the finger is scrolling, so it cancels.
export function createPress({ delay = 700, slop = 10, onStart = () => {}, onCancel = () => {}, onFire, schedule = setTimeout, cancel = clearTimeout }) {
  let timer = null;
  let origin = null;
  let fired = false;
  const stop = () => {
    if (timer === null) return;
    cancel(timer);
    timer = null;
    onCancel();
  };
  return {
    down(x, y) {
      stop();
      fired = false;
      origin = { x, y };
      onStart();
      timer = schedule(() => { timer = null; fired = true; onFire(); }, delay);
    },
    move(x, y) { if (timer !== null && Math.hypot(x - origin.x, y - origin.y) > slop) stop(); },
    up() { stop(); },
    consume() { const was = fired; fired = false; return was; },
  };
}
