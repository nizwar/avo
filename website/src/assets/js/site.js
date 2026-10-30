// Every page: the header and its menu, entrances as sections arrive, and
// click to zoom on screenshots; then each page's own piece: the windows of
// the hero, Avo's commands, the keys on the game, the held story, Avo Hub's
// index and its pairing walk-through.
// Nothing here is required to read the site; without JavaScript every
// word and picture is on the page.

import { setupLightbox } from './lightbox.js';
import { setupReel } from './reel.js';
import { setupCommands, setupKeys } from './commands.js';
import { setupIndex, setupPair, setupStory } from './story.js';

const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
document.documentElement.classList.add('js');

function setupHeader() {
  const header = document.querySelector('[data-header]');
  if (!header) return;
  const onScroll = () => header.classList.toggle('is-scrolled', window.scrollY > 8);
  onScroll();
  window.addEventListener('scroll', onScroll, { passive: true });

  const toggle = header.querySelector('[data-nav-toggle]');
  const nav = header.querySelector('[data-nav]');
  if (!toggle || !nav) return;
  const label = toggle.querySelector('[data-label-open]');
  const openLabel = label.textContent;
  const closeLabel = toggle.dataset.closeLabel || openLabel;
  const narrow = window.matchMedia('(max-width: 1000px)');

  const setOpen = (open) => {
    toggle.setAttribute('aria-expanded', String(open));
    nav.classList.toggle('is-open', open);
    header.classList.toggle('is-open', open);
    label.textContent = open ? closeLabel : openLabel;
  };
  const sync = () => {
    toggle.hidden = !narrow.matches;
    if (!narrow.matches) setOpen(false);
  };
  toggle.addEventListener('click', () => setOpen(toggle.getAttribute('aria-expanded') !== 'true'));
  nav.addEventListener('click', (event) => {
    if (event.target.closest('a')) setOpen(false);
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && toggle.getAttribute('aria-expanded') === 'true') {
      setOpen(false);
      toggle.focus();
    }
  });
  narrow.addEventListener('change', sync);
  sync();
}

/** Marks the menu link of the section being read. */
function setupCurrentSection() {
  const links = [...document.querySelectorAll('[data-nav] a[href*="#"]')];
  const map = new Map();
  for (const link of links) {
    const url = new URL(link.href);
    if (url.pathname !== window.location.pathname) continue;
    const target = url.hash && document.getElementById(decodeURIComponent(url.hash.slice(1)));
    if (target) map.set(target, link);
  }
  if (!map.size || !('IntersectionObserver' in window)) return;
  const io = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        for (const other of map.values()) if (other.getAttribute('aria-current') === 'location') other.removeAttribute('aria-current');
        const link = map.get(entry.target);
        if (!link.hasAttribute('aria-current')) link.setAttribute('aria-current', 'location');
      }
    },
    { rootMargin: '-45% 0px -50% 0px' },
  );
  for (const target of map.keys()) io.observe(target);
}

/**
 * Entrances: each section's parts below the fold arrive in reading order
 * (heading, words, picture, list), a beat apart, once. Nothing already on
 * screen is hidden, and nothing moves for visitors who prefer less motion.
 */
function setupRise() {
  if (reduceMotion.matches || !('IntersectionObserver' in window)) return;
  const parts = [
    '.h-display', '.h-sub', '.lead', '.command-search', '.command', '.keys-tabs', '.key-list > li', '.game-shot', '.story-figure', '.figure-item', '.teaser-shot', '.plain-list > li', '.channels > li',
    '.faq-item', '.cta-copy > *', '.dmg', '.index-item', '.index-stage', '.also-list > li', '.pair-stage', '.plan',
    '.req-list > div',
  ];
  const pictures = ['story-figure', 'teaser-shot', 'dmg', 'index-stage', 'pair-stage', 'game-shot'];
  const fold = window.innerHeight * 0.92;
  const io = new IntersectionObserver(
    (entries) => {
      const arriving = entries
        .filter((entry) => entry.isIntersecting)
        .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top || a.boundingClientRect.left - b.boundingClientRect.left);
      arriving.forEach((entry, i) => {
        const el = entry.target;
        el.style.setProperty('--rise-delay', `${Math.min(i, 4) * 75}ms`);
        el.classList.add('is-in');
        io.unobserve(el);
      });
    },
    { rootMargin: '0px 0px -8% 0px', threshold: 0.04 },
  );
  const selector = [...parts.map((part) => `main ${part}`), '.footer-slogan'].join(',');
  for (const el of document.querySelectorAll(selector)) {
    if (el.closest('.hero') || el.getBoundingClientRect().top < fold) continue;
    el.dataset.rise = pictures.some((name) => el.classList.contains(name)) ? 'picture' : 'text';
    io.observe(el);
  }
  window.addEventListener('beforeprint', () => {
    for (const el of document.querySelectorAll('[data-rise]')) el.classList.add('is-in');
  });
}

setupHeader();
setupCurrentSection();
setupReel({ reduceMotion });
setupCommands();
setupKeys();
setupStory();
setupIndex();
setupPair();
setupLightbox({ reduceMotion });
setupRise();
