'use strict';

const call = async (cmd, args = {}) =>
  JSON.parse(await window.webkit.messageHandlers.bridge.postMessage({ cmd, ...args }));

const $ = (s) => document.querySelector(s);
const el = (tag, props = {}, kids = []) => {
  const n = Object.assign(document.createElement(tag), props);
  for (const k of [].concat(kids)) n.append(k);
  return n;
};

const state = { day: null, bucketSeconds: 3600, rules: null, data: null };

function hms(sec) {
  const h = Math.floor(sec / 3600), m = Math.round((sec % 3600) / 60);
  return h ? `${h}h ${String(m).padStart(2, '0')}m` : `${m}m`;
}
const dayName = (epoch) =>
  new Date(epoch * 1000).toLocaleDateString(undefined,
    { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' });
const clock = (epoch) =>
  new Date(epoch * 1000).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });

// ---------- timeline ----------

async function loadDay() {
  state.data = await call('getDay', { day: state.day, bucketSeconds: state.bucketSeconds });
  state.day = state.data.dayStart;
  $('#dayLabel').textContent = dayName(state.day);
  renderChart();
  renderTotals();
  renderLabels();
}

function renderChart() {
  const { buckets, bucketSeconds } = state.data;
  const chart = $('#chart');
  chart.replaceChildren();

  if (!buckets.length) {
    chart.append(el('div', { className: 'empty', textContent: 'No activity recorded for this day.' }));
    $('#hours').replaceChildren();
    return;
  }

  // Buckets with no data are absent from the query, so rebuild the full span:
  // a gap is meaningful (app not running) and should read as empty, not missing.
  const byStart = new Map(buckets.map((b) => [b.start, b]));
  const first = buckets[0].start, last = buckets[buckets.length - 1].start;

  for (let t = first; t <= last; t += bucketSeconds) {
    const b = byStart.get(t);
    const col = el('div', { className: 'col' });
    col.dataset.start = t;
    if (b) {
      for (const c of b.cats) {
        col.append(el('div', {
          className: 'seg-block',
          style: `height:${(c.s / bucketSeconds) * 100}%;background:${c.color}`,
        }));
      }
    }
    chart.append(col);
  }

  const span = (last - first) / bucketSeconds + 1;
  const step = Math.max(1, Math.round(span / 8));
  const hours = $('#hours');
  hours.replaceChildren();
  for (let i = 0; i < span; i += step) {
    hours.append(el('span', {
      textContent: clock(first + i * bucketSeconds),
      style: `flex:${Math.min(step, span - i)} 1 0`,
    }));
  }
}

function renderTotals() {
  const box = $('#totals');
  box.replaceChildren();
  const max = Math.max(1, ...state.data.totals.map((t) => t.seconds));
  for (const t of state.data.totals) {
    box.append(el('div', {}, [
      el('span', { className: 'swatch', style: `background:${t.color}` }),
      el('span', { textContent: t.category, style: 'flex:0 0 96px' }),
      el('span', { className: 'meter' }, el('i', { style: `width:${(t.seconds / max) * 100}%;background:${t.color}` })),
      el('span', { className: 'mono', textContent: hms(t.seconds) }),
    ]));
  }
}

function renderLabels() {
  const rows = state.data.labels.map((l) =>
    el('tr', {}, [
      el('td', {}, el('span', { className: 'swatch', style: `background:${l.color}` })),
      el('td', { className: 'truncate', title: l.label, textContent: l.label }),
      el('td', { className: 'num', textContent: hms(l.seconds) }),
      el('td', { className: 'num', title: 'context switches', textContent: l.switches }),
    ]));
  $('#labels').replaceChildren(table(['', 'Activity', 'Time', 'Sw'], rows,
    'Nothing recorded yet.'));
}

function table(headers, rows, emptyMsg) {
  if (!rows.length) return el('div', { className: 'empty', textContent: emptyMsg });
  return el('table', {}, [
    el('thead', {}, el('tr', {}, headers.map((h) => el('th', { textContent: h })))),
    el('tbody', {}, rows),
  ]);
}

// ---------- tooltip ----------

const tip = $('#tip');
$('#chart').addEventListener('mousemove', (e) => {
  const col = e.target.closest('.col');
  if (!col) { tip.hidden = true; return; }
  const b = (state.data.buckets || []).find((x) => x.start === +col.dataset.start);
  tip.replaceChildren(el('b', { textContent: clock(+col.dataset.start) }));
  if (!b) {
    tip.append(el('div', { className: 'hint', textContent: 'no activity' }));
  } else {
    for (const c of b.cats) {
      tip.append(el('div', { className: 'r' }, [
        el('span', { className: 'swatch', style: `background:${c.color}` }),
        el('span', { textContent: c.c, style: 'flex:1' }),
        el('span', { className: 'mono', textContent: hms(c.s) }),
      ]));
    }
  }
  tip.hidden = false;
  const pad = 14;
  tip.style.left = Math.min(e.clientX + pad, window.innerWidth - tip.offsetWidth - 6) + 'px';
  tip.style.top = Math.min(e.clientY + pad, window.innerHeight - tip.offsetHeight - 6) + 'px';
});
$('#chart').addEventListener('mouseleave', () => { tip.hidden = true; });

// ---------- rules ----------

async function loadRules() {
  state.rules = await call('getRules');
  renderRules();
  renderCats();
  renderRaw();
}

function catOptions(selected) {
  const sel = el('select', {});
  for (const c of state.rules.categories) {
    sel.append(el('option', { value: c.name, textContent: c.name, selected: c.name === selected }));
  }
  return sel;
}

function renderRules() {
  const rows = state.rules.rules.map((r, i) => {
    const bind = (prop, cls) => {
      const input = el('input', { type: 'text', value: r[prop] || '', className: cls || '' });
      input.addEventListener('input', () => { r[prop] = input.value; });
      return input;
    };
    const cat = catOptions(r.category);
    cat.addEventListener('change', () => { r.category = cat.value; });

    const on = el('input', { type: 'checkbox', checked: r.enabled !== false });
    on.addEventListener('change', () => { r.enabled = on.checked; });

    const move = (delta) => {
      const j = i + delta;
      if (j < 0 || j >= state.rules.rules.length) return;
      const [x] = state.rules.rules.splice(i, 1);
      state.rules.rules.splice(j, 0, x);
      renderRules();
    };

    return el('tr', {}, [
      el('td', {}, on),
      el('td', {}, cat),
      el('td', {}, bind('app', 'code')),
      el('td', {}, bind('title', 'code')),
      el('td', {}, bind('url', 'code')),
      el('td', {}, bind('label')),
      el('td', {}, [
        button('↑', () => move(-1)),
        button('↓', () => move(1)),
        button('✕', () => { state.rules.rules.splice(i, 1); renderRules(); }, 'danger'),
      ]),
    ]);
  });
  $('#rulesTable').replaceChildren(
    table(['On', 'Category', 'App', 'Title', 'URL', 'Label', ''], rows, 'No rules yet.'));
}

function button(text, fn, cls = '') {
  const b = el('button', { className: `btn icon ${cls}`, textContent: text });
  b.addEventListener('click', fn);
  return b;
}

function renderCats() {
  const rows = state.rules.categories.map((c, i) => {
    const name = el('input', { type: 'text', value: c.name });
    name.addEventListener('input', () => { c.name = name.value; });
    const color = el('input', { type: 'color', value: c.color });
    color.addEventListener('input', () => { c.color = color.value; });
    return el('tr', {}, [
      el('td', {}, color),
      el('td', {}, name),
      el('td', {}, button('✕', () => { state.rules.categories.splice(i, 1); renderCats(); }, 'danger')),
    ]);
  });
  $('#catsTable').replaceChildren(table(['', 'Category', ''], rows, 'No categories.'));
}

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

async function renderRaw() {
  const raw = await call('getRaw', { day: state.day });
  const rows = raw.rows.map((r) => el('tr', {}, [
    el('td', {}, button('+', () => {
      state.rules.rules.unshift({
        category: state.rules.categories[0]?.name || 'Uncategorized',
        app: `^${escapeRe(r.app)}$`,
        title: r.title ? escapeRe(r.title) : '',
        url: '', label: '', enabled: true,
      });
      renderRules();
      $('#rulesTable').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    })),
    el('td', { className: 'truncate', title: r.bundleId, textContent: r.app }),
    el('td', { className: 'truncate', title: r.title, textContent: r.title || '—' }),
    el('td', { className: 'truncate', title: r.url, textContent: r.url || '' }),
    el('td', { className: 'truncate', textContent: r.label }),
    el('td', { className: 'num', textContent: hms(r.seconds) }),
  ]));
  $('#rawTable').replaceChildren(
    table(['', 'App', 'Raw title', 'URL', 'Resolves to', 'Time'], rows,
      'Nothing recorded for this day.'));
}

// ---------- wiring ----------

$('#addRule').addEventListener('click', () => {
  state.rules.rules.push({
    category: state.rules.categories[0]?.name || 'Uncategorized',
    app: '', title: '', url: '', label: '', enabled: true,
  });
  renderRules();
});

$('#addCat').addEventListener('click', () => {
  state.rules.categories.push({ name: 'New category', color: '#888888' });
  renderCats();
});

$('#saveRules').addEventListener('click', async () => {
  const res = await call('setRules', { rules: JSON.stringify(state.rules) });
  $('#saveMsg').textContent = res.ok ? 'Saved' : `Error: ${res.error}`;
  setTimeout(() => { $('#saveMsg').textContent = ''; }, 2500);
  if (res.ok) { await loadDay(); await renderRaw(); }
});

$('#prevDay').addEventListener('click', () => { state.day -= 86400; loadDay(); });
$('#nextDay').addEventListener('click', () => { state.day += 86400; loadDay(); });
$('#todayBtn').addEventListener('click', () => { state.day = null; loadDay(); });

$('#bucketSel').addEventListener('click', (e) => {
  const b = e.target.closest('[data-b]');
  if (!b) return;
  [...$('#bucketSel').children].forEach((c) => c.classList.toggle('is-on', c === b));
  state.bucketSeconds = +b.dataset.b;
  loadDay();
});

$('#tabs').addEventListener('click', (e) => {
  const b = e.target.closest('[data-tab]');
  if (!b) return;
  [...$('#tabs').children].forEach((c) => c.classList.toggle('is-on', c === b));
  $('#view-timeline').hidden = b.dataset.tab !== 'timeline';
  $('#view-rules').hidden = b.dataset.tab !== 'rules';
  if (b.dataset.tab === 'rules') renderRaw();
});

(async function init() {
  await loadRules();
  await loadDay();
  const s = await call('status');
  $('#status').textContent = s.trusted
    ? 'Recording'
    : 'Accessibility permission needed — window titles unavailable';
  $('#lastSeen').textContent = s.last || '';
})();
