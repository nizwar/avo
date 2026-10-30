// Held sections: the story on the home page (the statement being read is
// the bright one), Avo Hub's index (one window held beside its rows on wide
// screens, rows that open one at a time on narrow ones) and the pairing
// walk-through (the sheet follows the step being read; its buttons work).

/** Calls `onActive(index)` for the element nearest the middle of the screen. */
function watchMiddle(elements, onActive) {
  if (!elements.length || !('IntersectionObserver' in window)) return;
  const io = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) if (entry.isIntersecting) onActive(elements.indexOf(entry.target));
    },
    { rootMargin: '-45% 0px -45% 0px' },
  );
  for (const el of elements) io.observe(el);
}

export function setupStory() {
  const steps = [...document.querySelectorAll('[data-story] .story-step')];
  if (!steps.length) return;
  const activate = (index) => steps.forEach((step, i) => step.classList.toggle('is-active', i === index));
  activate(0);
  watchMiddle(steps, activate);
}

export function setupIndex() {
  const index = document.querySelector('[data-index]');
  if (!index) return;
  const stage = index.querySelector('[data-index-stage]');
  const items = [...index.querySelectorAll('[data-index-item]')].map((item) => ({
    item,
    row: item.querySelector('.index-row'),
    body: item.querySelector('.index-body'),
    figure: item.querySelector('.index-figure'),
  }));
  const wide = window.matchMedia('(min-width: 900px)');
  let current = 0;

  const open = (at) => {
    current = at;
    items.forEach(({ item, row, figure }, i) => {
      const on = i === at;
      item.classList.toggle('is-open', on);
      row.setAttribute('aria-expanded', String(on));
      figure.classList.toggle('is-current', on);
    });
  };

  // On wide screens the windows wait in one held frame beside the rows;
  // on narrow ones each stays under its own words.
  const layout = () => {
    index.classList.toggle('is-live', wide.matches);
    index.classList.toggle('is-folding', !wide.matches);
    for (const { body, figure } of items) {
      if (wide.matches) stage.append(figure);
      else body.append(figure);
    }
    stage.hidden = !wide.matches;
    open(current);
  };

  items.forEach(({ row }, i) => {
    row.addEventListener('click', () => open(i));
    row.addEventListener('keydown', (event) => {
      const step = { ArrowDown: 1, ArrowUp: -1 }[event.key];
      if (!step) return;
      const next = items[i + step];
      if (!next) return;
      event.preventDefault();
      next.row.focus();
      open(i + step);
    });
  });
  wide.addEventListener('change', layout);
  layout();
}

export function setupPair() {
  const section = document.querySelector('[data-pair]');
  if (!section) return;
  const steps = [...section.querySelectorAll('.pair-step')];
  const states = new Map([...section.querySelectorAll('[data-state]')].map((el) => [el.dataset.state, el]));
  const actions = section.querySelector('[data-pair-actions]');
  const cancelled = section.querySelector('[data-pair-cancelled]');

  const show = (name) => {
    for (const [key, el] of states) {
      const on = key === name;
      el.classList.toggle('is-current', on);
      el.inert = !on;
    }
    steps.forEach((step) => step.classList.toggle('is-active', step.dataset.step === name));
    if (name === 'code') reset();
  };
  const reset = () => {
    actions.hidden = false;
    cancelled.hidden = true;
  };

  section.querySelector('[data-pair-yes]').addEventListener('click', () => show('done'));
  section.querySelector('[data-pair-no]').addEventListener('click', () => {
    actions.hidden = true;
    cancelled.hidden = false;
    cancelled.querySelector('button').focus();
  });
  section.querySelector('[data-pair-again]').addEventListener('click', () => {
    reset();
    section.querySelector('[data-pair-yes]').focus();
  });

  const texts = [...section.querySelectorAll('[data-route]')];
  const route = (value) => texts.forEach((text) => text.classList.toggle('is-current', text.dataset.route === value));
  for (const radio of section.querySelectorAll('input[name="route"]')) {
    radio.addEventListener('change', () => route(radio.value));
  }
  route(section.querySelector('input[name="route"]:checked')?.value ?? 'cable');

  show('add');
  watchMiddle(steps, (i) => show(steps[i].dataset.step));
}
