'use strict';

const call = async (cmd, args = {}) =>
  JSON.parse(await window.webkit.messageHandlers.bridge.postMessage({ cmd, ...args }));

const $ = (s) => document.querySelector(s);
const el = (tag, props = {}, kids = []) => {
  const n = Object.assign(document.createElement(tag), props);
  for (const k of [].concat(kids)) n.append(k);
  return n;
};

const MIN = 60;         // seconds per timeline slice
const ZOOM_STEP = 1.6;
const ZOOM_MAX = 40;

const state = {
  view: 'timeline',
  day: null,
  minuteAct: null,      // Map of minute -> activity index, built lazily for hover
  group: 'day',         // list view: one group for the day, or one per hour
  bucketSeconds: 3600,
  zoom: 1,              // 1 = whole span fits the panel
  selected: null,       // bucket start when drilled in, else null
  first: 0,             // epoch of the leftmost column, set by renderChart
  pitch: 0,             // px per bucket, set by renderChart
  rules: null,
  data: null,
  list: null,
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

const minutes = (sec) => `${Math.round(sec / 60)}m`;

// ---------- day load ----------

/// Every view is scoped to state.day, so day navigation just reloads whichever
/// one is on screen.
async function refresh() {
  if (state.view === 'list') return loadList();
  if (state.view === 'timeline') return loadDay();
  return renderRaw();
}

async function loadList() {
  state.list = await call('getList', { day: state.day, group: state.group });
  state.day = state.list.dayStart;
  $('#dayLabel').textContent = dayName(state.day);
  renderList();
}

async function loadDay() {
  state.data = await call('getDay', { day: state.day, bucketSeconds: state.bucketSeconds });
  state.day = state.data.dayStart;
  state.selected = null;
  state.minuteAct = null;
  $('#dayLabel').textContent = dayName(state.day);
  renderChart();
  renderBreakdown();
}

// ---------- list view ----------

function renderList() {
  const host = $('#listTable');
  const { rows, group, hidden } = state.list;
  if (!rows.length) {
    host.replaceChildren(el('div', { className: 'empty', textContent: 'Nothing recorded this day.' }));
    return;
  }

  // The backend emits rows in first-seen order; reversing puts the most recent
  // activity at the top so the day reads backwards as you scroll down.
  const byGroup = new Map();
  for (const r of [...rows].reverse()) {
    if (!byGroup.has(r.group)) byGroup.set(r.group, []);
    byGroup.get(r.group).push(r);
  }
  const hiddenBy = new Map(hidden.map((h) => [h.group, h]));

  const body = el('tbody');
  for (const [g, list] of byGroup) {
    if (group === 'hour') {
      const total = list.reduce((a, r) => a + r.seconds, 0);
      body.append(el('tr', { className: 'group' }, [
        el('td', { colSpan: 3, textContent: `${clock(g)} – ${clock(g + 3600)}` }),
        el('td', { className: 'num mono', textContent: minutes(total) }),
        el('td', {}),
      ]));
    }
    for (const r of list) {
      body.append(el('tr', {}, [
        el('td', { className: 'cat', title: r.category }, [
          el('span', { className: 'swatch', style: `background:${r.color}` }),
          el('span', { textContent: ` ${r.category}` }),
        ]),
        el('td', { className: 'title', title: r.label, textContent: r.label }),
        el('td', { className: 'num', textContent: clock(r.start) }),
        el('td', { className: 'num', textContent: minutes(r.seconds) }),
        el('td', { className: 'num', title: 'switches', textContent: r.switches }),
      ]));
    }
    const h = hiddenBy.get(g);
    if (h) {
      body.append(el('tr', { className: 'muted' }, [
        el('td', { colSpan: 3, textContent: `${h.count} activity spans under 5m not shown` }),
        el('td', { className: 'num', textContent: minutes(h.seconds) }),
        el('td', {}),
      ]));
    }
  }

  host.replaceChildren(el('table', { className: 'log' }, [
    el('colgroup', {}, ['c-cat', 'c-act', 'c-start', 'c-min', 'c-cnt']
      .map((c) => el('col', { className: c }))),
    el('thead', {}, el('tr', {}, [
      el('th', { textContent: 'Category' }),
      el('th', { textContent: 'Activity' }),
      el('th', { className: 'num', textContent: 'Start' }),
      el('th', { className: 'num', textContent: 'Time' }),
      el('th', { className: 'num', textContent: '⇄', title: 'Times you switched into this activity' }),
    ])),
    body,
  ]));
}

// ---------- timeline ----------

/// Minutes with no data are absent from the query, so the strip rebuilds the
/// full span: a gap means "app wasn't running" and reads as bare track.
function spanOf(data) {
  if (!data.minutes.length) return null;
  const first = data.minutes[0][0];
  const last = data.minutes[data.minutes.length - 1][0];
  return { first, last, count: (last - first) / MIN + 1 };
}

function renderChart() {
  const canvas = $('#strip'), axis = $('#axis'), inner = $('#tlInner');
  axis.replaceChildren();
  $('#cursor').hidden = true;

  const sp = spanOf(state.data);
  $('#tlEmpty').hidden = !!sp;
  $('#tlScroll').hidden = !sp;
  if (!sp) {
    state.pitch = 0;
    syncZoomButtons();
    return;
  }

  const avail = $('#tlScroll').clientWidth - 16;            // minus container padding
  const pitch = Math.max(avail / sp.count, 0.1) * state.zoom;
  const totalW = sp.count * pitch;
  state.first = sp.first;
  state.pitch = pitch;
  inner.style.width = `${totalW}px`;

  const h = parseFloat(getComputedStyle(canvas).height) || 58;
  const dpr = window.devicePixelRatio || 1;
  canvas.style.width = `${totalW}px`;
  canvas.width = Math.round(totalW * dpr);
  canvas.height = Math.round(h * dpr);
  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, totalW, h);

  const { acts, actCats, palette } = state.data;
  for (const [t, ai] of state.data.minutes) {
    ctx.fillStyle = palette[actCats[ai]] || '#6b7280';
    // Half a pixel of overlap: fractional minute widths would otherwise leave
    // hairline seams between neighbouring slices.
    ctx.fillRect(((t - sp.first) / MIN) * pitch, 0, pitch + 0.5, h);
  }

  if (state.selected !== null) {
    const x0 = ((state.selected - sp.first) / MIN) * pitch;
    const x1 = x0 + (state.bucketSeconds / MIN) * pitch;
    ctx.fillStyle = 'rgba(0,0,0,.45)';
    ctx.fillRect(0, 0, Math.max(0, x0), h);
    ctx.fillRect(x1, 0, Math.max(0, totalW - x1), h);
    ctx.strokeStyle = getComputedStyle(document.body).getPropertyValue('--accent').trim();
    ctx.lineWidth = 2;
    ctx.strokeRect(x0 + 1, 1, Math.max(2, x1 - x0 - 2), h - 2);
  }

  renderAxis(sp, pitch);
  syncZoomButtons();
}

/// Ticks land on real clock hours (and half hours once there is room), never on
/// whatever arbitrary minute the day's first observation happens to fall in.
function renderAxis(sp, pitch) {
  const axis = $('#axis');
  const x = (t) => ((t - sp.first) / MIN) * pitch;
  const end = sp.first + sp.count * MIN;
  const hourPx = (3600 / MIN) * pitch;
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
  let totals, labels, hidden;
  if (state.selected === null) {
    ({ totals, labels, hidden } = state.data);
  } else {
    ({ totals, labels, hidden } = await call('getRange', {
      from: state.selected, to: state.selected + state.bucketSeconds,
    }));
  }
  renderCrumb();
  renderTotals(totals);
  renderLabels(labels, hidden);
}

function renderCrumb() {
  const crumb = $('#crumb');
  crumb.replaceChildren();
  if (state.selected === null) { crumb.hidden = true; return; }

  const end = state.selected + state.bucketSeconds;
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

function renderLabels(labels, hidden) {
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
  if (hidden && hidden.count) {
    body.append(el('tr', { className: 'muted' }, [
      el('td', {}),
      el('td', { textContent: `${hidden.count} activity spans under 5m not shown` }),
      el('td', { className: 'num', textContent: hms(hidden.seconds) }),
      el('td', {}),
    ]));
  }
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

/// Which minute the pointer is over, or null when the strip is empty.
function minuteAt(e) {
  if (!state.pitch) return null;
  const x = e.clientX - $('#strip').getBoundingClientRect().left;
  return state.first + Math.floor(x / state.pitch) * MIN;
}

$('#strip').addEventListener('click', (e) => {
  const t = minuteAt(e);
  if (t === null) return;
  // The 5m/15m/1h control sets how wide a slice the drill-down covers.
  const start = Math.floor(t / state.bucketSeconds) * state.bucketSeconds;
  state.selected = state.selected === start ? null : start;
  renderChart();
  renderBreakdown();
});

const tip = $('#tip');
$('#strip').addEventListener('mousemove', (e) => {
  const t = minuteAt(e);
  if (t === null) { tip.hidden = true; return; }

  if (!state.minuteAct) state.minuteAct = new Map(state.data.minutes);
  const ai = state.minuteAct.get(t);
  const { acts, actCats, actApps, palette } = state.data;

  tip.replaceChildren(el('b', { textContent: clock(t) }));
  if (ai === undefined) {
    tip.append(el('div', { className: 'hint', textContent: 'no activity recorded' }));
  } else {
    // Idle and Locked resolve to a label that is just the pseudo-app's name.
    const same = acts[ai] === actApps[ai];
    tip.append(el('div', { className: 'act' }, [
      el('strong', { textContent: actApps[ai] }),
      el('span', { textContent: same ? '' : ` ${acts[ai]}` }),
    ]));
    tip.append(el('div', { className: 'r' }, [
      el('span', { className: 'swatch', style: `background:${palette[actCats[ai]] || '#6b7280'}` }),
      el('span', { textContent: actCats[ai] }),
    ]));
  }
  tip.hidden = false;

  const cur = $('#cursor');
  cur.style.left = `${((t - state.first) / MIN) * state.pitch}px`;
  cur.style.width = `${Math.max(1, state.pitch)}px`;
  cur.hidden = false;

  // Parked below the axis and centred on the pointer: a tooltip that tracked
  // the cursor vertically covered the very slices you were scrubbing across.
  const half = tip.offsetWidth / 2;
  tip.style.left = `${Math.max(6, Math.min(e.clientX - half, window.innerWidth - tip.offsetWidth - 6))}px`;
  tip.style.top = `${$('#axis').getBoundingClientRect().bottom - 2}px`;
});
$('#strip').addEventListener('mouseleave', () => {
  tip.hidden = true;
  $('#cursor').hidden = true;
});

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
    // Drop the cached views so they re-resolve under the new rules when shown.
    state.data = null;
    state.list = null;
    await renderRaw();
  }
});

$('#prevDay').addEventListener('click', () => { state.day -= 86400; refresh(); });
$('#nextDay').addEventListener('click', () => { state.day += 86400; refresh(); });
$('#todayBtn').addEventListener('click', () => { state.day = null; refresh(); });

/// Holds the right-hand edge of the viewport fixed in time. At the default
/// scroll position that edge is the newest bucket, so zooming in moves toward
/// now rather than toward the start of the day.
function zoomBy(factor) {
  const sc = $('#tlScroll');
  if (!state.pitch) return;
  const anchor = state.first + ((sc.scrollLeft + sc.clientWidth) / state.pitch) * MIN;

  state.zoom = Math.min(ZOOM_MAX, Math.max(1, state.zoom * factor));
  renderChart();

  sc.scrollLeft = ((anchor - state.first) / MIN) * state.pitch - sc.clientWidth;
}

$('#zoomIn').addEventListener('click', () => zoomBy(ZOOM_STEP));
$('#zoomOut').addEventListener('click', () => zoomBy(1 / ZOOM_STEP));

$('#bucketSel').addEventListener('click', (e) => {
  const b = e.target.closest('[data-b]');
  if (!b) return;
  [...$('#bucketSel').children].forEach((c) => c.classList.toggle('is-on', c === b));
  state.bucketSeconds = +b.dataset.b;
  state.selected = null;      // the strip is unchanged; only the drill-down width moved
  renderChart();
  renderBreakdown();
});

$('#groupSel').addEventListener('click', (e) => {
  const b = e.target.closest('[data-g]');
  if (!b) return;
  [...$('#groupSel').children].forEach((c) => c.classList.toggle('is-on', c === b));
  state.group = b.dataset.g;
  loadList();
});

function showView(name) {
  state.view = name;
  for (const v of ['list', 'timeline', 'rules']) $(`#view-${v}`).hidden = v !== name;
  [...$('#tabs').children].forEach((c) => c.classList.toggle('is-on', c.dataset.tab === name));
  $('#groupSel').hidden = name !== 'list';
  $('#bucketSel').hidden = name !== 'timeline';
  $('#zoomSel').hidden = name !== 'timeline';
}

$('#tabs').addEventListener('click', async (e) => {
  const b = e.target.closest('[data-tab]');
  if (!b) return;
  showView(b.dataset.tab);
  if (b.dataset.tab === 'timeline') {
    // Column widths are only measurable once the section is visible.
    if (!state.data) await loadDay(); else renderChart();
  } else {
    await refresh();
  }
});

window.addEventListener('resize', () => {
  if (state.view === 'timeline' && state.data) renderChart();
});

(async function init() {
  await loadRules();
  showView('timeline');
  await loadDay();
  const s = await call('status');
  $('#status').textContent = s.trusted
    ? 'Recording'
    : 'Accessibility permission needed — window titles unavailable';
  $('#lastSeen').textContent = s.last || '';
})();
