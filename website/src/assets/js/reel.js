// The hero's windows: Avo's library, a match, the key editor and the
// settings, one at a time. They cross-fade every six seconds (the
// signature move), and the tabs under them pick one; picking stops the
// slideshow, as does the pause button. It rests while off screen or in a
// hidden tab, and never starts for visitors who prefer less motion.

const HOLD = 6000;

export function setupReel({ reduceMotion }) {
  const stage = document.querySelector('[data-reel]');
  const items = stage ? [...stage.querySelectorAll('[data-reel-item]')] : [];
  if (items.length < 2) return;

  const bar = document.createElement('div');
  bar.className = 'reel-bar';
  const tabs = document.createElement('div');
  tabs.className = 'reel-tabs';
  tabs.setAttribute('role', 'tablist');
  tabs.setAttribute('aria-label', stage.dataset.reelLabel || '');
  const caption = document.createElement('p');
  caption.className = 'reel-caption';

  let current = 0;
  let timer = null;
  let playing = !reduceMotion.matches;
  let visible = true;
  let held = false; // the pointer or focus is on the stage

  const buttons = items.map((item, i) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'reel-tab';
    button.id = `${item.id}-tab`;
    button.setAttribute('role', 'tab');
    button.setAttribute('aria-controls', item.id);
    button.textContent = item.dataset.tab;
    item.setAttribute('role', 'tabpanel');
    item.setAttribute('aria-labelledby', button.id);
    button.addEventListener('click', () => {
      stop();
      show(i);
    });
    button.addEventListener('keydown', (event) => {
      const step = { ArrowRight: 1, ArrowLeft: -1, Home: -i, End: items.length - 1 - i }[event.key];
      if (step === undefined) return;
      event.preventDefault();
      stop();
      const next = (i + step + items.length) % items.length;
      show(next);
      buttons[next].focus();
    });
    tabs.append(button);
    return button;
  });

  const pause = document.createElement('button');
  pause.type = 'button';
  pause.className = 'reel-pause';
  const setPauseLabel = () => {
    pause.setAttribute('aria-label', playing ? stage.dataset.pauseLabel : stage.dataset.playLabel);
    pause.innerHTML = `<svg class="icon" aria-hidden="true" focusable="false"><use href="#i-${playing ? 'pause' : 'play'}"/></svg>`;
  };
  pause.addEventListener('click', () => {
    playing = !playing;
    setPauseLabel();
    schedule();
  });

  bar.append(tabs);
  if (!reduceMotion.matches) bar.append(pause);
  stage.append(bar, caption);
  setPauseLabel();

  function show(index) {
    current = index;
    items.forEach((item, i) => {
      const on = i === index;
      item.classList.toggle('is-current', on);
      item.inert = !on;
      item.setAttribute('aria-hidden', String(!on));
      buttons[i].setAttribute('aria-selected', String(on));
      buttons[i].tabIndex = on ? 0 : -1;
    });
    caption.textContent = items[index].querySelector('figcaption')?.textContent ?? '';
    schedule();
  }

  function stop() {
    playing = false;
    setPauseLabel();
    schedule();
  }

  function schedule() {
    clearTimeout(timer);
    if (!playing || !visible || held || document.hidden) return;
    timer = setTimeout(() => show((current + 1) % items.length), HOLD);
  }

  stage.addEventListener('pointerenter', () => { held = true; schedule(); });
  stage.addEventListener('pointerleave', () => { held = false; schedule(); });
  stage.addEventListener('focusin', () => { held = true; schedule(); });
  stage.addEventListener('focusout', (event) => {
    if (!stage.contains(event.relatedTarget)) {
      held = false;
      schedule();
    }
  });
  document.addEventListener('visibilitychange', schedule);
  if ('IntersectionObserver' in window) {
    new IntersectionObserver((entries) => {
      visible = entries.some((e) => e.isIntersecting);
      schedule();
    }).observe(stage);
  }
  reduceMotion.addEventListener('change', () => {
    if (reduceMotion.matches) stop();
  });

  // The other windows wait until the first one has loaded.
  const first = items[0].querySelector('img');
  const warm = () => {
    for (const img of stage.querySelectorAll('img[loading="lazy"]')) img.loading = 'eager';
  };
  if (first?.complete) warm();
  else first?.addEventListener('load', warm, { once: true });

  show(0);
}
