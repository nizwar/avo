// Motion that follows the pointer. Only for a mouse or trackpad (a device
// that can hover, with a fine pointer), and never when the visitor prefers
// reduced motion:
// - cards and screenshots marked [data-tilt] lean toward the pointer, a soft
//   light (.glare) follows it across them, and their [data-tilt-depth] layer
//   floats a little above;
// - buttons lean toward the pointer and light up under it;
// - over the hero, a warm light follows the pointer, the screenshot leans and
//   the haze's own light drifts toward it;
// - the glows behind the sections drift with the pointer;
// - the Dock drawn in "On your Mac" magnifies its icons like the real one.
// Only transform and opacity change (and the width of the Dock's backdrop,
// a layer out of the flow), from one requestAnimationFrame loop that
// stops as soon as nothing moves. Each frame reads layout first and writes
// styles after, and reads it again only after a scroll or resize. Sections
// off screen are left alone.

const PRESETS = {
  card: { max: 6, perspective: 900, depth: 8, glare: true },
  tile: { max: 3.2, perspective: 1500, depth: 10, glare: true },
  shot: { max: 3.5, perspective: 1500, depth: 0, glare: true },
  deck: { max: 4.5, perspective: 1600, depth: 0, glare: true, parallax: true },
  lit: { max: 0, perspective: 0, depth: 0, glare: true },
};

const pointer = { x: 0, y: 0, active: false };
let enabled = false;
let layoutVersion = 0;
let viewWidth = window.innerWidth;

const clamp = (v, lo = -1, hi = 1) => (v < lo ? lo : v > hi ? hi : v);
/** Frame-rate independent easing toward `to` (rate: how quickly, per second). */
const approach = (from, to, dt, rate) => from + (to - from) * (1 - Math.exp(-rate * dt));
const round = (v, digits = 3) => Number(v.toFixed(digits));
const settled = (a, b, eps = 0.002) => Math.abs(a - b) < eps;

// ------------------------------------------------------------------ the loop

const moving = new Set();
let frame = 0;
let last = 0;

function wake(mover) {
  if (!enabled || !mover) return;
  moving.add(mover);
  if (!frame) {
    last = performance.now();
    frame = requestAnimationFrame(tick);
  }
}

function tick(now) {
  frame = 0;
  const dt = Math.min(0.05, Math.max(0.001, (now - last) / 1000));
  last = now;
  const list = [...moving];
  for (const mover of list) mover.measure?.();
  for (const mover of list) if (!mover.update(dt)) moving.delete(mover);
  if (moving.size) frame = requestAnimationFrame(tick);
}

/** The light layer of a card or screenshot, made on first use. */
function glareOf(host) {
  let glare = host.querySelector(':scope > .glare');
  if (!glare) {
    glare = document.createElement('span');
    glare.className = 'glare';
    glare.setAttribute('aria-hidden', 'true');
    const picture = host.querySelector(':scope > picture');
    if (picture) picture.after(glare);
    else host.prepend(glare);
  }
  return glare;
}

// --------------------------------------------------------- tilt and light

function makeTilt(host, hovered) {
  const preset = PRESETS[host.dataset.tilt] || PRESETS.card;
  const target = host.querySelector('[data-tilt-target]') || host;
  const depth = preset.depth ? host.querySelector('[data-tilt-depth]') : null;
  // The games deck lights the screenshot in front, whichever it is.
  const lightHost = () => (host.dataset.tilt === 'deck' ? host.querySelector('.is-front .shot') : host);
  let glareHost = null;
  let glare = null;
  let rect = null;
  let glareRect = null;
  let version = -1;
  let inside = false;
  let nx = 0;
  let ny = 0;
  let light = 0;

  const mover = {
    remeasure() {
      version = -1;
    },
    measure() {
      if (version === layoutVersion) return;
      version = layoutVersion;
      rect = host.getBoundingClientRect();
      const next = preset.glare ? lightHost() : null;
      if (next !== glareHost) {
        if (glare) glare.style.opacity = '';
        glareHost = next;
        glare = next ? glareOf(next) : null;
      }
      glareRect = glareHost ? glareHost.getBoundingClientRect() : null;
    },
    update(dt) {
      let tx = 0;
      let ty = 0;
      if (inside && rect?.width) {
        tx = clamp(((pointer.x - rect.left) / rect.width) * 2 - 1);
        ty = clamp(((pointer.y - rect.top) / rect.height) * 2 - 1);
        // Hold almost still while a hotspot's tip is being read.
        if (host.classList.contains('is-calm')) {
          tx *= 0.2;
          ty *= 0.2;
        }
      }
      const lit = inside ? 1 : 0;
      nx = approach(nx, tx, dt, 8);
      ny = approach(ny, ty, dt, 8);
      light = approach(light, lit, dt, inside ? 7 : 4);
      const done = settled(nx, tx) && settled(ny, ty) && settled(light, lit, 0.01);
      if (done && !inside) {
        mover.reset();
        return false;
      }
      if (preset.max) {
        target.style.transform = `perspective(${preset.perspective}px) rotateX(${round(-ny * preset.max)}deg) rotateY(${round(nx * preset.max)}deg)`;
      }
      if (preset.parallax) {
        target.style.setProperty('--px', String(round(nx)));
        target.style.setProperty('--py', String(round(ny)));
      }
      if (depth) depth.style.transform = `translate3d(${round(nx * preset.depth, 2)}px, ${round(ny * preset.depth, 2)}px, 0)`;
      if (glare && glareRect) {
        if (inside) {
          glare.style.setProperty('--gx', `${round(pointer.x - glareRect.left, 1)}px`);
          glare.style.setProperty('--gy', `${round(pointer.y - glareRect.top, 1)}px`);
        }
        glare.style.opacity = String(round(light));
      }
      return !done;
    },
    reset() {
      nx = 0;
      ny = 0;
      light = 0;
      target.style.transform = '';
      target.style.removeProperty('--px');
      target.style.removeProperty('--py');
      if (depth) depth.style.transform = '';
      if (glare) glare.style.opacity = '';
    },
  };

  host.addEventListener('pointerenter', (event) => {
    if (!enabled || event.pointerType === 'touch') return;
    inside = true;
    version = -1;
    hovered.add(mover);
    wake(mover);
  }, { passive: true });
  host.addEventListener('pointerleave', () => {
    inside = false;
    hovered.delete(mover);
    wake(mover);
  }, { passive: true });
  return mover;
}

// ----------------------------------------------------------------- buttons

function makeMagnet(button, hovered) {
  let rect = null;
  let version = -1;
  let inside = false;
  let x = 0;
  let y = 0;
  let light = 0;

  const mover = {
    measure() {
      if (version === layoutVersion) return;
      version = layoutVersion;
      // Where the button sits without the pull already applied.
      const r = button.getBoundingClientRect();
      rect = { left: r.left - x, top: r.top - y, width: r.width, height: r.height };
    },
    update(dt) {
      let tx = 0;
      let ty = 0;
      if (inside && rect) {
        tx = clamp((pointer.x - (rect.left + rect.width / 2)) * 0.2, -6, 6);
        ty = clamp((pointer.y - (rect.top + rect.height / 2)) * 0.3, -4, 4);
      }
      const lit = inside ? 1 : 0;
      x = approach(x, tx, dt, 12);
      y = approach(y, ty, dt, 12);
      light = approach(light, lit, dt, inside ? 10 : 5);
      const done = settled(x, tx, 0.02) && settled(y, ty, 0.02) && settled(light, lit, 0.01);
      if (done && !inside) {
        mover.reset();
        return false;
      }
      button.style.translate = `${round(x, 2)}px ${round(y, 2)}px`;
      if (inside && rect) {
        button.style.setProperty('--lx', `${round(pointer.x - rect.left - x, 1)}px`);
        button.style.setProperty('--ly', `${round(pointer.y - rect.top - y, 1)}px`);
      }
      button.style.setProperty('--lit', String(round(light)));
      return !done;
    },
    reset() {
      x = 0;
      y = 0;
      light = 0;
      button.style.translate = '';
      button.style.removeProperty('--lx');
      button.style.removeProperty('--ly');
      button.style.removeProperty('--lit');
    },
  };

  button.addEventListener('pointerenter', (event) => {
    if (!enabled || event.pointerType === 'touch') return;
    inside = true;
    version = -1;
    hovered.add(mover);
    wake(mover);
  }, { passive: true });
  button.addEventListener('pointerleave', () => {
    inside = false;
    hovered.delete(mover);
    wake(mover);
  }, { passive: true });
  return mover;
}

// -------------------------------------------------------------------- hero

function makeHero(hero, haze) {
  const shot = hero.querySelector('.hero-shot');
  const sky = hero.querySelector('.hero-sky');
  const light = hero.querySelector('.hero-light');
  let rect = null;
  let shotRect = null;
  let version = -1;
  let glare = null;
  let nx = 0;
  let ny = 0;
  let lx = 0;
  let ly = 0;
  let glow = 0;
  let placed = false;

  const mover = {
    inView: true,
    measure() {
      if (version === layoutVersion) return;
      version = layoutVersion;
      rect = hero.getBoundingClientRect();
      shotRect = shot ? shot.getBoundingClientRect() : null;
      if (shot && !glare) glare = glareOf(shot);
    },
    update(dt) {
      const inside = mover.inView && pointer.active && rect && pointer.y >= rect.top && pointer.y <= rect.bottom;
      const tx = inside ? clamp((pointer.x / viewWidth) * 2 - 1) : 0;
      const ty = inside ? clamp(((pointer.y - rect.top) / rect.height) * 2 - 1) : 0;
      const lit = inside ? 1 : 0;
      nx = approach(nx, tx, dt, 3.2);
      ny = approach(ny, ty, dt, 3.2);
      if (inside) {
        const px = pointer.x - rect.left;
        const py = pointer.y - rect.top;
        if (!placed) {
          lx = px;
          ly = py;
          placed = true;
        }
        lx = approach(lx, px, dt, 5);
        ly = approach(ly, py, dt, 5);
      }
      glow = approach(glow, lit, dt, inside ? 2.4 : 3);
      if (haze) {
        haze.active = Boolean(inside);
        if (inside) {
          haze.x = (pointer.x - rect.left) / rect.width;
          haze.y = 1 - (pointer.y - rect.top) / rect.height;
        }
      }
      const done = settled(nx, tx) && settled(ny, ty) && settled(glow, lit, 0.01) && (!inside || (settled(lx, pointer.x - rect.left, 0.5) && settled(ly, pointer.y - rect.top, 0.5)));
      if (done && !inside) {
        mover.reset();
        return false;
      }
      if (shot) {
        shot.style.transform = `perspective(1600px) rotateX(${round(-ny * 3)}deg) rotateY(${round(nx * 4.5)}deg) translate3d(${round(nx * -8, 2)}px, ${round(ny * -6, 2)}px, 0)`;
      }
      if (sky) sky.style.transform = `translate3d(${round(nx * -18, 2)}px, ${round(ny * -12, 2)}px, 0)`;
      if (light) {
        light.style.transform = `translate3d(${round(lx, 1)}px, ${round(ly, 1)}px, 0)`;
        light.style.opacity = String(round(glow));
      }
      if (glare && shotRect && inside) {
        glare.style.setProperty('--gx', `${round(pointer.x - shotRect.left, 1)}px`);
        glare.style.setProperty('--gy', `${round(pointer.y - shotRect.top, 1)}px`);
      }
      if (glare) glare.style.opacity = String(round(glow * 0.85));
      return !done;
    },
    reset() {
      nx = 0;
      ny = 0;
      glow = 0;
      placed = false;
      if (haze) haze.active = false;
      if (shot) shot.style.transform = '';
      if (sky) sky.style.transform = '';
      if (light) {
        light.style.transform = '';
        light.style.opacity = '';
      }
      if (glare) glare.style.opacity = '';
    },
  };
  return mover;
}

// ------------------------------------------------------------ section glows

function makeGlows(elements) {
  const glows = elements.map((el) => ({ el, inView: false, x: 0, y: 0 }));
  const mover = {
    glows,
    get anyInView() {
      return glows.some((g) => g.inView);
    },
    update(dt) {
      const tx = pointer.active ? clamp((pointer.x / viewWidth) * 2 - 1) : 0;
      const ty = pointer.active ? clamp((pointer.y / window.innerHeight) * 2 - 1) : 0;
      let busy = false;
      for (const g of glows) {
        if (!g.inView) continue;
        g.x = approach(g.x, tx, dt, 1.8);
        g.y = approach(g.y, ty, dt, 1.8);
        if (!settled(g.x, tx) || !settled(g.y, ty)) busy = true;
        g.el.style.transform = `translate3d(${round(g.x * 44, 1)}px, ${round(g.y * 30, 1)}px, 0)`;
      }
      return busy;
    },
    reset() {
      for (const g of glows) {
        g.x = 0;
        g.y = 0;
        g.el.style.transform = '';
      }
    },
  };
  return mover;
}

// ------------------------------------------------------------------- dock

// The icons near the pointer grow from the bottom, and, as in the real Dock,
// they push their neighbours aside rather than cover them: every icon (and
// the separator) moves over by what the icons before it have grown, the row
// stays centred, and the backdrop widens with it (--dock-grow).
function makeDock(dock, hovered) {
  const items = [...dock.children];
  const scales = items.map(() => 1);
  let slots = [];
  let version = -1;
  let inside = false;

  const mover = {
    measure() {
      if (version === layoutVersion) return;
      version = layoutVersion;
      // Untransformed places (offsets, not boxes), so a measure taken while
      // icons are magnified is still right. Icons hidden at this width have
      // no place.
      const left = dock.getBoundingClientRect().left;
      slots = items.flatMap((el, i) => {
        if (!el.offsetWidth) return [];
        const s = getComputedStyle(el);
        // Its place in the row: the box less any negative margin (the Avo
        // icon is drawn larger than its place).
        const width = el.offsetWidth + Math.min(0, parseFloat(s.marginLeft) || 0) + Math.min(0, parseFloat(s.marginRight) || 0);
        return [{ el, i, center: left + el.offsetLeft + el.offsetWidth / 2, width, grows: !el.classList.contains('dock-sep') }];
      });
    },
    update(dt) {
      let busy = false;
      let grown = 0;
      const extra = slots.map((slot) => {
        let goal = 1;
        if (inside && slot.grows) {
          const reach = Math.min(Math.abs(pointer.x - slot.center) / 130, 1);
          goal = 1 + 0.42 * Math.cos((reach * Math.PI) / 2) ** 2;
        }
        scales[slot.i] = approach(scales[slot.i], goal, dt, 14);
        if (!settled(scales[slot.i], goal, 0.001)) busy = true;
        const more = (scales[slot.i] - 1) * slot.width;
        grown += more;
        return more;
      });
      let before = 0;
      slots.forEach((slot, n) => {
        const s = scales[slot.i];
        const dx = before + extra[n] / 2 - grown / 2;
        before += extra[n];
        slot.el.style.transform = s > 1.001 || Math.abs(dx) > 0.05 ? `translate(${round(dx, 2)}px, ${round(-(s - 1) * 18, 2)}px) scale(${round(s)})` : '';
      });
      dock.style.setProperty('--dock-grow', `${round(grown, 2)}px`);
      // Back at rest: no trace of the magnification is left behind.
      if (!inside && !busy) this.reset();
      return busy;
    },
    reset() {
      items.forEach((el, i) => {
        scales[i] = 1;
        el.style.transform = '';
      });
      dock.style.removeProperty('--dock-grow');
    },
  };

  dock.addEventListener('pointerenter', (event) => {
    if (!enabled || event.pointerType === 'touch') return;
    inside = true;
    version = -1;
    hovered.add(mover);
    wake(mover);
  }, { passive: true });
  dock.addEventListener('pointerleave', () => {
    inside = false;
    hovered.delete(mover);
    wake(mover);
  }, { passive: true });
  return mover;
}

// ------------------------------------------------------------------- setup

export function setupMotion({ reduceMotion, hazePointer = null }) {
  const fine = window.matchMedia('(hover: hover) and (pointer: fine)');
  const hovered = new Set();
  const all = [];

  for (const channel of document.querySelectorAll('.channel')) channel.dataset.tilt ||= 'lit';
  const tiltHosts = [...document.querySelectorAll('[data-tilt]')];
  const tilts = tiltHosts.map((host) => makeTilt(host, hovered));
  all.push(...tilts);
  for (const button of document.querySelectorAll('.btn')) all.push(makeMagnet(button, hovered));
  for (const dock of document.querySelectorAll('.mini-dock')) all.push(makeDock(dock, hovered));

  const heroEl = document.querySelector('[data-hero]');
  const hero = heroEl ? makeHero(heroEl, hazePointer) : null;
  if (hero) all.push(hero);
  const glows = makeGlows([...document.querySelectorAll('.section > .glow')]);
  all.push(glows);

  // Only what is on screen follows the pointer.
  if ('IntersectionObserver' in window) {
    const owners = new Map();
    if (hero) owners.set(heroEl, (on) => {
      hero.inView = on;
      wake(hero);
    });
    for (const g of glows.glows) owners.set(g.el.parentElement, (on) => {
      g.inView = on;
      // Off screen, a glow drops its transform (and so its GPU layer); it
      // glides back toward the pointer when it returns.
      if (!on) {
        g.x = 0;
        g.y = 0;
        g.el.style.transform = '';
      }
    });
    const io = new IntersectionObserver((entries) => {
      for (const entry of entries) owners.get(entry.target)?.(entry.isIntersecting);
    });
    for (const el of owners.keys()) io.observe(el);
  } else {
    for (const g of glows.glows) g.inView = true;
  }

  // The games deck lights whichever screenshot comes to the front.
  const deck = tilts[tiltHosts.findIndex((host) => host.dataset.tilt === 'deck')];
  document.querySelector('[data-showcase]')?.addEventListener('showcase:change', () => {
    deck?.remeasure();
    wake(deck);
  });

  window.addEventListener('pointermove', (event) => {
    if (!enabled || event.pointerType === 'touch') return;
    pointer.x = event.clientX;
    pointer.y = event.clientY;
    pointer.active = true;
    for (const mover of hovered) wake(mover);
    if (hero?.inView) wake(hero);
    if (glows.anyInView) wake(glows);
  }, { passive: true });
  const away = () => {
    pointer.active = false;
    wake(hero);
    wake(glows);
  };
  document.documentElement.addEventListener('pointerleave', away, { passive: true });
  window.addEventListener('blur', away);
  window.addEventListener('scroll', () => {
    layoutVersion++;
    // The page moved under a still pointer.
    for (const mover of hovered) wake(mover);
    if (hero?.inView) wake(hero);
  }, { passive: true });
  window.addEventListener('resize', () => {
    layoutVersion++;
    viewWidth = window.innerWidth;
  }, { passive: true });

  const sync = () => {
    const on = fine.matches && !reduceMotion.matches;
    if (on === enabled) return;
    enabled = on;
    document.documentElement.classList.toggle('has-pointer-motion', on);
    if (!on) {
      if (frame) cancelAnimationFrame(frame);
      frame = 0;
      moving.clear();
      hovered.clear();
      pointer.active = false;
      if (hazePointer) hazePointer.active = false;
      for (const mover of all) mover.reset();
    }
  };
  sync();
  fine.addEventListener?.('change', sync);
  reduceMotion.addEventListener?.('change', sync);
}
