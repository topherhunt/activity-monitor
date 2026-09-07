'use strict';

const call = async (cmd, args = {}) =>
  JSON.parse(await window.webkit.messageHandlers.bridge.postMessage({ cmd, ...args }));

const $ = (s) => document.querySelector(s);
const el = (tag, props = {}, kids = []) => {
  const n = Object.assign(document.createElement(tag), props);
  for (const k of [].concat(kids)) n.append(k);
  return n;
};

const GAP = 1;          // px between timeline columns
const ZOOM_STEP = 1.6;
const ZOOM_MAX = 40;

const state = {
  day: null,
  bucketSeconds: 3600,
  zoom: 1,              // 1 = whole span fits the panel
  selected: null,       // bucket start when drilled in, else null
  rules: null,
  data: null,
};

function hms(sec) {
  const h = Math.floor(sec / 3600), m = Math.round((sec % 3600) / 60);
  return h ? `${h}h ${String(m).padStart(2, '0')}m` : `${m}m`;
}
const dayName = (epoch) =>
  new Date(epoch * 1000).toLocaleDateString(undefined,
    { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' });
const clock = (epoch, withMinutes = true) =>
  new Date(epoch * 1000).toLocaleTimeString(undefined,
    withMinutes ? { hour: 'numeric', minute: '2-digit' } : { hour: 'numeric' });

// ---------- day load ----------

async function loadDay() {
  state.data = await call('getDay', { day: state.day, bucketSeconds: state.bucketSeconds });
  state.day = state.data.dayStart;
  state.selected = null;
  $('#dayLabel').textContent = dayName(state.day);
  renderChart();
  renderBreakdown();
}

// ---------- timeline ----------

/// Buckets with no data are absent from the query, so the chart rebuilds the
/// full span: a gap means "app wasn't running" and should read as empty space.
function spanOf(data) {
  if (!data.buckets.length) return null;
  const first = data.buckets[0].start;
  const last = data.buckets[data.buckets.length - 1].start;
  return { first, last, count: (last - first) / data.bucketSeconds + 1 };
}

function renderChart() {
  const chart = $('#chart'), axis = $('#axis'), inner = $('#tlInner');
  chart.replaceChildren();
  axis.replaceChildren();

  const sp = spanOf(state.data);
  if (!sp) {
    inner.style.width = '100%';
    chart.append(el('div', { className: 'empty', textContent: 'No activity recorded for this day.' }));
    syncZoomButtons();
    return;
  }

  const { bucketSeconds } = state.data;
  const avail = $('#tlScroll').clientWidth - 16;            // minus container padding
  const fitW = Math.max(2, (avail - (sp.count - 1) * GAP) / sp.count);
  const colW = fitW * state.zoom;
  const pitch = colW + GAP;
  inner.style.width = `${sp.count * colW + (sp.count - 1) * GAP}px`;

  const byStart = new Map(state.data.buckets.map((b) => [b.start, b]));
  chart.classList.toggle('has-sel', state.selected !== null);

  for (let i = 0; i < sp.count; i++) {
    const t = sp.first + i * bucketSeconds;
    const b = byStart.get(t);
    const col = el('div', { className: 'col' });
    col.style.cssText = `width:${colW}px;flex:0 0 auto`;
    col.dataset.start = t;
    if (t === state.selected) col.classList.add('is-sel');
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

  renderAxis(sp, bucketSeconds, pitch);
  syncZoomButtons();
}

/// Ticks land on real clock hours (and half hours once there is room), never on
/// whatever arbitrary time the first bucket happens to start at.
function renderAxis(sp, bucketSeconds, pitch) {
  const axis = $('#axis');
  const x = (t) => ((t - sp.first) / bucketSeconds) * pitch;
  const end = sp.first + sp.count * bucketSeconds;
  const hourPx = (3600 / bucketSeconds) * pitch;
  const labelEvery = Math.max(1, Math.ceil(52 / hourPx));
  const showHalf = hourPx >= 120;

  let n = 0;
  for (let t = Math.ceil(sp.first / 3600) * 3600; t < end; t += 3600, n++) {
    axis.append(el('div', { className: 'tick hour', style: `left:${x(t)}px` }));
    if (n % labelEvery === 0) {
      axis.append(el('div', {
        className: 'tick-label',
        style: `left:${x(t)}px`,
        textContent: clock(t, false),
      }));
    }
    if (showHalf && t + 1800 < end) {
      axis.append(el('div', { className: 'tick half', style: `left:${x(t + 1800)}px` }));
      axis.append(el('div', {
        className: 'tick-label half', style: `left:${x(t + 1800)}px`,
        textContent: clock(t + 1800),
      }));
    }
  }
}

function syncZoomButtons() {
  $('#zoomOut').disabled = state.zoom <= 1;
  $('#zoomIn').disabled = state.zoom >= ZOOM_MAX;
}

// ---------- breakdown panels ----------

async function renderBreakdown() {
  let totals, labels;
  if (state.selected === null) {
    ({ totals, labels } = state.data);
  } else {
    ({ totals, labels } = await call('getRange', {
      from: state.selected, to: state.selected + state.data.bucketSeconds,
    }));
  }
  renderCrumb();
  renderTotals(totals);
  renderLabels(labels);
}

function renderCrumb() {
  const crumb = $('#crumb');
  crumb.replaceChildren();
  if (state.selected === null) { crumb.hidden = true; return; }

  const end = state.selected + state.data.bucketSeconds;
  const back = el('button', { className: 'link', textContent: 'Whole day' });
  back.addEventListener('click', clearSelection);
  const close = el('button', { className: 'btn icon', textContent: '✕', title: 'Clear selection' });
  close.addEventListener('click', clearSelection);

  crumb.append(back,
    el('span', { className: 'sep', textContent: '›' }),
    el('span', { className: 'cur', textContent: `${clock(state.selected)} – ${clock(end)}` }),
    close);
  crumb.hidden = false;
}

function clearSelection() {
  state.selected = null;
  renderChart();
  renderBreakdown();
}

function renderTotals(totals) {
  const box = $('#totals');
  box.replaceChildren();
  if (!totals.length) {
    box.append(el('div', { className: 'empty', textContent: 'Nothing here.' }));
    return;
  }
  const max = Math.max(1, ...totals.map((t) => t.seconds));
  for (const t of totals) {
    box.append(el('div', {}, [
      el('span', { className: 'swatch', style: `background:${t.color}` }),
      el('span', { textContent: t.category, style: 'flex:0 0 92px' }),
      el('span', { className: 'meter' },
        el('i', { style: `width:${(t.seconds / max) * 100}%;background:${t.color}` })),
      el('span', { className: 'mono', textContent: hms(t.seconds) }),
    ]));
  }
}

function renderLabels(labels) {
  const host = $('#labels');
  if (!labels.length) {
    host.replaceChildren(el('div', { className: 'empty', textContent: 'Nothing recorded here.' }));
    return;
  }
  const cols = el('colgroup', {}, ['c-sw', 'c-title', 'c-time', 'c-cnt']
    .map((c) => el('col', { className: c })));
  const head = el('thead', {}, el('tr', {}, [
    el('th', {}),
    el('th', { textContent: 'Activity' }),
    el('th', { className: 'num', textContent: 'Time' }),
    el('th', { className: 'num', textContent: '⇄', title: 'Times you switched into this activity' }),
  ]));
  const body = el('tbody', {}, labels.map((l) => el('tr', {}, [
    el('td', {}, el('span', { className: 'swatch', style: `background:${l.color}` })),
    el('td', { className: 'title', title: `${l.label}\n${l.category}`, textContent: l.label }),
    el('td', { className: 'num', textContent: hms(l.seconds) }),
    el('td', { className: 'num', title: 'switches', textContent: l.switches }),
  ])));
  host.replaceChildren(el('table', { className: 'activities' }, [cols, head, body]));
}

function table(headers, rows, emptyMsg) {
  if (!rows.length) return el('div', { className: 'empty', textContent: emptyMsg });
  return el('table', {}, [
    el('thead', {}, el('tr', {}, headers.map((h) => el('th', { textContent: h })))),
    el('tbody', {}, rows),
  ]);
}

// ---------- chart interaction ----------

$('#chart').addEventListener('click', (e) => {
  const col = e.target.closest('.col');
  if (!col) return;
  const start = +col.dataset.start;
  state.selected = state.selected === start ? null : start;
  renderChart();
  renderBreakdown();
});

const tip = $('#tip');
$('#chart').addEventListener('mousemove', (e) => {
  const col = e.target.closest('.col');
  if (!col) { tip.hidden = true; return; }
  const start = +col.dataset.start;
  const b = (state.data.buckets || []).find((x) => x.start === start);
  tip.replaceChildren(el('b', {
    textContent: `${clock(start)} – ${clock(start + state.data.bucketSeconds)}`,
  }));
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
  if (res.ok) {
    const keep = state.selected;
    await loadDay();
    state.selected = keep;
    renderChart();
    await renderBreakdown();
    await renderRaw();
  }
});

$('#prevDay').addEventListener('click', () => { state.day -= 86400; loadDay(); });
$('#nextDay').addEventListener('click', () => { state.day += 86400; loadDay(); });
$('#todayBtn').addEventListener('click', () => { state.day = null; loadDay(); });

$('#zoomIn').addEventListener('click', () => {
  state.zoom = Math.min(ZOOM_MAX, state.zoom * ZOOM_STEP);
  renderChart();
});
$('#zoomOut').addEventListener('click', () => {
  state.zoom = Math.max(1, state.zoom / ZOOM_STEP);
  renderChart();
});

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
  else renderChart();          // widths are only measurable while visible
});

window.addEventListener('resize', () => {
  if (!$('#view-timeline').hidden && state.data) renderChart();
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
