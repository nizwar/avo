// Avo's commands, scaled up: a search field filters them, one is open at a
// time on the accent, and the arrow keys move between them. And the games:
// pick a key on the dark field and a ring shows where it lands on the game;
// tabs switch between a match and the key editor.

const fold = (text) => text.toLocaleLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');

export function setupCommands() {
  const menu = document.querySelector('[data-commands]');
  if (!menu) return;
  const search = menu.querySelector('[data-command-search]');
  const input = search.querySelector('input');
  const empty = menu.querySelector('[data-command-empty]');
  const items = [...menu.querySelectorAll('.command')].map((item) => ({
    item,
    row: item.querySelector('.command-row'),
    words: fold(`${item.querySelector('.command-name').textContent} ${item.dataset.terms} ${item.querySelector('.command-text').textContent}`),
  }));
  search.hidden = false;

  const visible = () => items.filter(({ item }) => !item.hidden);
  const open = (target) => {
    for (const entry of items) {
      const on = entry === target;
      entry.item.classList.toggle('is-open', on);
      entry.row.setAttribute('aria-expanded', String(on));
    }
  };

  items.forEach((entry) => {
    entry.row.addEventListener('click', () => open(entry));
    entry.row.addEventListener('focus', () => open(entry));
    entry.row.addEventListener('keydown', (event) => {
      const list = visible();
      const at = list.indexOf(entry);
      const next = { ArrowDown: list[at + 1], ArrowUp: list[at - 1], Home: list[0], End: list.at(-1) }[event.key];
      if (event.key === 'ArrowUp' && at === 0) {
        event.preventDefault();
        input.focus();
        return;
      }
      if (!next) return;
      event.preventDefault();
      next.row.focus();
    });
  });

  input.addEventListener('input', () => {
    const query = fold(input.value.trim());
    const terms = query.split(/\s+/).filter(Boolean);
    for (const entry of items) entry.item.hidden = !terms.every((term) => entry.words.includes(term));
    const list = visible();
    empty.textContent = list.length ? '' : menu.dataset.empty;
    if (list.length && !list.some(({ item }) => item.classList.contains('is-open'))) open(list[0]);
  });
  input.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowDown' || event.key === 'Enter') {
      const first = visible()[0];
      if (!first) return;
      event.preventDefault();
      first.row.focus();
    }
  });

  open(items[0]);
}

export function setupKeys() {
  const section = document.querySelector('[data-keys]');
  if (!section) return;
  const sets = [...section.querySelectorAll('[data-keyset]')];
  const shots = new Map([...section.querySelectorAll('[data-shot]')].map((shot) => [shot.dataset.shot, shot]));

  const press = (set, key) => {
    const shot = shots.get(set.id);
    for (const other of set.querySelectorAll('.key')) other.setAttribute('aria-pressed', String(other === key));
    for (const mark of shot.querySelectorAll('.mark')) mark.classList.toggle('is-on', mark.dataset.markId === key.dataset.mark);
  };
  for (const set of sets) {
    for (const key of set.querySelectorAll('.key')) {
      key.addEventListener('click', () => press(set, key));
      key.addEventListener('pointerenter', (event) => {
        if (event.pointerType === 'mouse') press(set, key);
      });
    }
    press(set, set.querySelector('.key'));
  }

  // Tabs for the two screens, above the keys.
  const tabs = document.createElement('div');
  tabs.className = 'keys-tabs';
  tabs.setAttribute('role', 'tablist');
  tabs.setAttribute('aria-label', section.dataset.tabsLabel || '');
  const buttons = sets.map((set, i) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'keys-tab';
    button.id = `${set.id}-tab`;
    button.setAttribute('role', 'tab');
    button.setAttribute('aria-controls', set.id);
    button.textContent = set.dataset.tab;
    set.setAttribute('role', 'tabpanel');
    set.setAttribute('aria-labelledby', button.id);
    button.addEventListener('click', () => select(i));
    button.addEventListener('keydown', (event) => {
      const step = { ArrowRight: 1, ArrowLeft: -1 }[event.key];
      if (!step) return;
      event.preventDefault();
      const next = (i + step + sets.length) % sets.length;
      select(next);
      buttons[next].focus();
    });
    tabs.append(button);
    return button;
  });
  section.querySelector('.games-input .lead').after(tabs);

  function select(index) {
    sets.forEach((set, i) => {
      const on = i === index;
      set.hidden = !on;
      shots.get(set.id).hidden = !on;
      buttons[i].setAttribute('aria-selected', String(on));
      buttons[i].tabIndex = on ? 0 : -1;
    });
  }
  select(0);
}
