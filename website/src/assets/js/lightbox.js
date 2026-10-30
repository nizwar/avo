// Click to zoom: every [data-zoom] screenshot gets a button (and a click on
// the picture itself) that opens it large in a modal <dialog>. The large
// image grows out of the screenshot on the page and shrinks back into it
// (FLIP, transform and opacity only); with reduced motion it simply appears.
// The dialog keeps focus inside, Escape and a click anywhere close it, and
// focus returns to where it was.

const EASE_OUT = 'cubic-bezier(0.16, 1, 0.3, 1)';
const EASE_IN_OUT = 'cubic-bezier(0.65, 0, 0.35, 1)';

/** The transform that puts `to` exactly over `from` (both client rects). */
const flip = (from, to) =>
  `translate(${from.left - to.left}px, ${from.top - to.top}px) scale(${from.width / to.width}, ${from.height / to.height})`;

/** The srcset of the same format as the picture's current image. */
function bestSrcset(picture, img) {
  const url = (img.currentSrc || img.src).split('?')[0];
  const ext = url.slice(url.lastIndexOf('.'));
  for (const el of [...picture.querySelectorAll('source'), img]) {
    const set = el.getAttribute('srcset') || '';
    if (set.includes(ext)) return set;
  }
  return img.getAttribute('srcset') || '';
}

export function setupLightbox({ reduceMotion }) {
  const dialog = document.querySelector('[data-lightbox]');
  if (!dialog || typeof dialog.showModal !== 'function') return;
  const figure = dialog.querySelector('[data-lightbox-figure]');
  const caption = dialog.querySelector('[data-lightbox-caption]');
  const scrim = dialog.querySelector('[data-lightbox-scrim]');
  const closeButton = dialog.querySelector('[data-lightbox-close]');
  const label = dialog.dataset.zoomLabel || '';
  const big = document.createElement('img');
  big.className = 'lightbox-img';
  big.decoding = 'async';
  big.alt = '';
  figure.prepend(big);

  let source = null;
  let trigger = null;
  let closing = false;
  const animate = () => !reduceMotion.matches && typeof big.animate === 'function';

  function open(shot, from) {
    const img = shot.querySelector('img');
    const picture = img?.closest('picture');
    if (!img || !picture || dialog.open) return;
    source = img;
    trigger = from;
    // Start with the image already on screen, then let the browser pick a
    // sharper one for the large size.
    big.removeAttribute('srcset');
    big.src = img.currentSrc || img.src;
    big.width = Number(img.getAttribute('width')) || img.naturalWidth;
    big.height = Number(img.getAttribute('height')) || img.naturalHeight;
    big.alt = img.alt;
    big.sizes = `(max-width: ${big.width}px) 96vw, ${big.width}px`;
    big.srcset = bestSrcset(picture, img);

    // A caption under the screenshot, or the words it illustrates.
    const figcaption = shot.closest('figure')?.querySelector('figcaption');
    const host = shot.closest('.story-step, .index-item, [data-shot]');
    const title = host?.querySelector('h3')?.textContent ?? '';
    const text = figcaption?.textContent.trim() || host?.querySelector('h3 ~ p, .index-body > p')?.textContent || '';
    caption.replaceChildren();
    if (title) {
      const strong = document.createElement('strong');
      strong.textContent = title;
      caption.append(strong);
    }
    if (text) caption.append(document.createTextNode(text));
    caption.hidden = !title && !text;

    const gap = window.innerWidth - document.documentElement.clientWidth;
    document.documentElement.style.setProperty('--scrollbar-gap', `${gap}px`);
    document.documentElement.classList.add('has-lightbox');
    dialog.showModal();
    closeButton.focus({ preventScroll: true });

    if (!animate()) return;
    const start = img.getBoundingClientRect();
    const end = big.getBoundingClientRect();
    big.animate([{ transform: flip(start, end) }, { transform: 'none' }], { duration: 620, easing: EASE_OUT });
    scrim.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 420, easing: 'ease-out' });
    for (const el of [caption, closeButton]) {
      el.animate([{ opacity: 0, transform: 'translateY(8px)' }, { opacity: 1, transform: 'none' }], { duration: 480, delay: 180, easing: EASE_OUT, fill: 'backwards' });
    }
  }

  async function close() {
    if (!dialog.open || closing) return;
    closing = true;
    if (animate() && source) {
      const end = source.getBoundingClientRect();
      const onScreen = end.bottom > 0 && end.top < window.innerHeight && end.width > 0;
      const start = big.getBoundingClientRect();
      const motions = [
        scrim.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 360, easing: 'ease-in', fill: 'forwards' }),
        ...[caption, closeButton].map((el) => el.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 160, fill: 'forwards' })),
        onScreen
          ? big.animate([{ transform: 'none' }, { transform: flip(end, start) }], { duration: 420, easing: EASE_IN_OUT, fill: 'forwards' })
          : big.animate([{ opacity: 1, transform: 'none' }, { opacity: 0, transform: 'scale(0.96)' }], { duration: 260, easing: 'ease-in', fill: 'forwards' }),
      ];
      await Promise.all(motions.map((m) => m.finished.catch(() => {})));
      dialog.close();
      for (const m of motions) m.cancel();
    } else {
      dialog.close();
    }
    document.documentElement.classList.remove('has-lightbox');
    document.documentElement.style.removeProperty('--scrollbar-gap');
    trigger?.focus({ preventScroll: true });
    closing = false;
  }

  dialog.addEventListener('cancel', (event) => {
    event.preventDefault();
    close();
  });
  dialog.addEventListener('click', () => close());

  for (const shot of document.querySelectorAll('[data-zoom]')) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'zoom-btn';
    button.setAttribute('aria-label', label);
    button.innerHTML = '<svg class="icon" aria-hidden="true" focusable="false"><use href="#i-zoom"/></svg>';
    shot.append(button);
    shot.classList.add('is-zoomable');
    button.addEventListener('click', (event) => {
      event.stopPropagation();
      open(shot, button);
    });
    shot.addEventListener('click', (event) => {
      if (event.target.closest('button, a')) return;
      open(shot, button);
    });
  }
}
