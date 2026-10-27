/* Fatigue dashboard: fetches /api/analytics and draws the page. */
/* global Chart */
(() => {
  'use strict';

  const SEVERITIES = ['Warning', 'High', 'Critical'];
  const SEV_TOKEN = { Warning: '--warning', High: '--serious', Critical: '--critical', warning: '--warning', high: '--serious', critical: '--critical' };
  const REFRESH_MS = 60000;

  const $ = (id) => document.getElementById(id);
  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const charts = {};
  let overview = null;
  let sessions = [];
  let timeline = null;
  let tz = 'Africa/Johannesburg';

  // ======================================
  // SETTINGS (remembered per browser)
  // ======================================
  const store = {
    get(k) { try { return localStorage.getItem(`fatigue-dash:${k}`); } catch { return null; } },
    set(k, v) { try { localStorage.setItem(`fatigue-dash:${k}`, v); } catch { /* private mode */ } },
  };
  const state = {
    days: store.get('days') ?? '30',
    measure: store.get('measure') ?? 'count',
    includeDemo: store.get('includeDemo') === 'true',
    sessionId: null,
  };
  // Link settings win over remembered ones, e.g. /dashboard/?days=7&demo=1&measure=rate
  const params = new URLSearchParams(window.location.search);
  if (params.has('days')) state.days = params.get('days');
  if (params.has('demo')) state.includeDemo = params.get('demo') === '1';
  if (['count', 'rate'].includes(params.get('measure'))) state.measure = params.get('measure');

  // ======================================
  // FORMATTING
  // ======================================
  const nf = new Intl.NumberFormat('en-GB');
  const num = (n, dp = 0) => (n == null ? '–' : nf.format(Number(n.toFixed(dp))));
  function duration(min) {
    if (min == null) return '–';
    const m = Math.round(min);
    const h = Math.floor(m / 60);
    if (h === 0) return `${m} min`;
    return m % 60 ? `${h} h ${m % 60} min` : `${h} h`;
  }
  const shortDuration = (min) => {
    const h = Math.floor(min / 60);
    const m = Math.round(min % 60);
    return h ? (m ? `${h}h${String(m).padStart(2, '0')}` : `${h}h`) : `${m}m`;
  };
  const hourLabel = (h) => `${String(h).padStart(2, '0')}:00`;
  const hourRange = (h) => `${hourLabel(h)}–${hourLabel((h + 1) % 24)}`;
  let dateFmt;
  const when = (iso) => dateFmt.format(new Date(iso));

  // Status icons: shape differs per severity so colour is never the only cue.
  function sevIcon(sev) {
    const color = css(SEV_TOKEN[sev]);
    const shapes = {
      Warning: '<polygon points="8,1.5 15,14.5 1,14.5"/>',
      High: '<polygon points="8,1 15,8 8,15 1,8"/>',
      Critical: '<polygon points="5,1 11,1 15,5 15,11 11,15 5,15 1,11 1,5"/>',
    };
    return `<svg viewBox="0 0 16 16" aria-hidden="true" fill="${color}">${shapes[sev]}</svg>`;
  }
  function sevBadge(sev) {
    const span = document.createElement('span');
    span.className = 'sev';
    span.innerHTML = sevIcon(sev);
    span.append(document.createTextNode(sev));
    return span;
  }

  function el(tag, attrs = {}, ...children) {
    const node = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
      if (k === 'class') node.className = v;
      else if (k === 'text') node.textContent = v;
      else node.setAttribute(k, v);
    }
    for (const c of children) if (c != null) node.append(c);
    return node;
  }

  function table(headers, rows) {
    const t = el('table', { class: 'data' });
    const head = el('tr');
    headers.forEach((h) => head.append(el('th', { class: h.num ? 'num' : '', text: h.label })));
    t.append(el('thead', {}, head));
    const body = el('tbody');
    for (const r of rows) {
      const tr = el('tr', { class: r.flag ? 'flag' : '' });
      r.cells.forEach((c, i) => {
        const td = el('td', { class: headers[i].num ? 'num' : '' });
        if (c instanceof Node) td.append(c); else td.textContent = c;
        tr.append(td);
      });
      body.append(tr);
    }
    t.append(body);
    return t;
  }

  // ======================================
  // DATA
  // ======================================
  async function getJSON(path) {
    const res = await fetch(path, { credentials: 'same-origin', headers: { Accept: 'application/json' } });
    if (res.status === 401) { window.location.reload(); throw new Error('Password required'); }
    const body = await res.json();
    if (!res.ok || !body.success) throw new Error(body.message || `Request failed (${res.status})`);
    return body.data;
  }
  const query = () => {
    const p = new URLSearchParams();
    if (state.days) p.set('days', state.days);
    if (state.includeDemo) p.set('includeDemo', 'true');
    return p.toString();
  };

  async function refresh() {
    try {
      const [o, s] = await Promise.all([
        getJSON(`/api/analytics/overview?${query()}`),
        getJSON(`/api/analytics/sessions?${query()}`),
      ]);
      overview = o;
      sessions = s;
      tz = o.timezone;
      dateFmt = new Intl.DateTimeFormat('en-GB', { timeZone: tz, weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
      renderAll();
      await loadTimeline();
      $('updated').textContent = `Updated ${new Intl.DateTimeFormat('en-GB', { timeZone: tz, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date())}`;
    } catch (e) {
      $('updated').textContent = `Could not load data: ${e.message}`;
    }
  }

  async function loadTimeline() {
    const select = $('session-select');
    const ids = sessions.map((s) => String(s.id));
    if (!ids.includes(state.sessionId)) {
      // Default to the most recent drive that has fatigue events, else the most recent.
      state.sessionId = String((sessions.find((s) => s.events > 0) || sessions[0] || {}).id || '');
    }
    select.replaceChildren(...sessions.map((s) => {
      const text = `${when(s.startedAt)} · ${s.pilotId} · ${duration(s.durationMinutes)} · ${s.events} event${s.events === 1 ? '' : 's'}${s.isDemo ? ' (demo)' : ''}`;
      const opt = el('option', { value: String(s.id), text });
      if (String(s.id) === state.sessionId) opt.selected = true;
      return opt;
    }));
    $('timeline-empty').hidden = sessions.length > 0;
    $('timeline').hidden = sessions.length === 0;
    if (!state.sessionId) return;
    try {
      timeline = await getJSON(`/api/analytics/sessions/${state.sessionId}/timeline`);
      renderTimeline();
    } catch (e) {
      $('timeline-empty').textContent = `Could not load this drive: ${e.message}`;
      $('timeline-empty').hidden = false;
    }
  }

  // ======================================
  // CHART.JS SHARED STYLE
  // ======================================
  function chartTheme() {
    Chart.defaults.font.family = 'system-ui, -apple-system, "Segoe UI", sans-serif';
    Chart.defaults.font.size = 12;
    Chart.defaults.color = css('--text-muted');
    Chart.defaults.animation = false;
    Chart.defaults.locale = 'en-GB'; // dot decimals, matching the rest of the page
  }
  const axis = (extra = {}) => ({
    grid: { color: css('--grid'), lineWidth: 1, drawTicks: false },
    border: { color: css('--axis') },
    ticks: { color: css('--text-muted'), padding: 6 },
    ...extra,
  });
  const tooltipStyle = () => ({
    backgroundColor: css('--surface'),
    titleColor: css('--text-primary'),
    bodyColor: css('--text-primary'),
    footerColor: css('--text-secondary'),
    borderColor: css('--border'),
    borderWidth: 1,
    padding: 10,
    boxPadding: 4,
    usePointStyle: true,
    titleFont: { weight: '600' },
    footerFont: { weight: '400' },
  });

  // Horizontal reference line for the average rate (solid hairline + label).
  const avgLinePlugin = {
    id: 'avgLine',
    afterDatasetsDraw(chart, _args, opts) {
      if (opts.value == null) return;
      const y = chart.scales.y.getPixelForValue(opts.value);
      const { left, right } = chart.chartArea;
      const { ctx } = chart;
      ctx.save();
      ctx.strokeStyle = css('--text-secondary');
      ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(left, y); ctx.lineTo(right, y); ctx.stroke();
      ctx.fillStyle = css('--text-secondary');
      ctx.font = '11px system-ui, sans-serif';
      ctx.textAlign = 'right';
      ctx.fillText(opts.label, right, y - 4);
      ctx.restore();
    },
  };

  // Vertical lines at fatigue events + a crosshair at the hovered x.
  const markersPlugin = {
    id: 'markers',
    afterDatasetsDraw(chart, _args, opts) {
      const { ctx, chartArea: { top, bottom } } = chart;
      ctx.save();
      for (const m of opts.events || []) {
        const x = chart.scales.x.getPixelForValue(m.minute);
        ctx.strokeStyle = css(SEV_TOKEN[m.severity]);
        ctx.lineWidth = 2;
        ctx.beginPath(); ctx.moveTo(x, top); ctx.lineTo(x, bottom); ctx.stroke();
      }
      const active = chart.tooltip?.getActiveElements?.()[0];
      if (active) {
        ctx.strokeStyle = css('--text-muted');
        ctx.lineWidth = 1;
        ctx.beginPath(); ctx.moveTo(active.element.x, top); ctx.lineTo(active.element.x, bottom); ctx.stroke();
      }
      ctx.restore();
    },
  };

  function replaceChart(key, canvas, config) {
    charts[key]?.destroy();
    charts[key] = new Chart(canvas, config);
  }

  // ======================================
  // BAR CHARTS (hour / drive time / day)
  // ======================================
  function legendFor(container, measure) {
    container.replaceChildren();
    if (measure === 'count') {
      for (const sev of SEVERITIES) {
        const s = el('span');
        s.innerHTML = sevIcon(sev);
        s.append(document.createTextNode(sev));
        container.append(s);
      }
    } else {
      const item = (color, text, pattern) => {
        const sw = el('i', { class: 'swatch' });
        sw.style.background = pattern || color;
        return el('span', {}, sw, document.createTextNode(text));
      };
      container.append(
        item(css('--accent'), 'Events per driving hour'),
        el('span', {}, (() => { const s = el('span'); s.innerHTML = sevIcon('Critical'); return s; })(), document.createTextNode(`Dangerous (≥ ${overview.thresholds.dangerRatio}× average)`)),
        item(css('--muted-fill'), 'Not enough driving to judge'),
        el('span', {}, (() => { const k = el('i', { class: 'line-key' }); k.style.background = css('--text-secondary'); return k; })(), document.createTextNode('Average')),
      );
    }
  }

  function barChart(key, canvas, labels, slots, slotTitle) {
    const measure = state.measure;
    const surface = css('--surface');
    const avgRate = overview.totals.eventsPerDrivingHour;
    let datasets;

    if (measure === 'count') {
      datasets = SEVERITIES.map((sev) => ({
        label: sev,
        data: slots.map((s) => s[sev]),
        backgroundColor: css(SEV_TOKEN[sev]),
        borderColor: surface,
        borderWidth: { top: 2 },
        borderSkipped: 'bottom',
        maxBarThickness: 24,
        // Round only the top visible segment of each stack.
        borderRadius: (ctx) => {
          const i = ctx.dataIndex;
          let topIndex = -1;
          ctx.chart.data.datasets.forEach((d, k) => { if (d.data[i] > 0) topIndex = k; });
          return ctx.datasetIndex === topIndex ? { topLeft: 4, topRight: 4 } : 0;
        },
        stack: 'events',
      }));
    } else {
      datasets = [{
        label: 'Events per driving hour',
        data: slots.map((s) => (s.enoughData ? s.rate : (s.rate ?? 0))),
        backgroundColor: slots.map((s) => (s.danger ? css('--critical') : s.enoughData ? css('--accent') : css('--muted-fill'))),
        borderRadius: { topLeft: 4, topRight: 4 },
        borderSkipped: 'bottom',
        maxBarThickness: 24,
      }];
    }

    replaceChart(key, canvas, {
      type: 'bar',
      data: { labels, datasets },
      plugins: [avgLinePlugin],
      options: {
        maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        scales: {
          x: axis({ stacked: true, grid: { display: false }, ticks: { color: css('--text-muted'), maxRotation: 0, autoSkip: true, autoSkipPadding: 8 } }),
          y: axis({ stacked: true, beginAtZero: true, ticks: { color: css('--text-muted'), precision: measure === 'count' ? 0 : undefined, maxTicksLimit: 6 } }),
        },
        plugins: {
          legend: { display: false },
          avgLine: { value: measure === 'rate' && avgRate ? avgRate : null, label: `Average ${num(avgRate, 2)}/h` },
          tooltip: {
            ...tooltipStyle(),
            callbacks: {
              title: (items) => slotTitle(slots[items[0].dataIndex]),
              label: (item) => (measure === 'count'
                ? `${item.dataset.label}: ${num(item.raw)}`
                : `${num(item.raw, 2)} events per driving hour`),
              footer: (items) => {
                const s = slots[items[0].dataIndex];
                const lines = [`${num(s.total)} events in ${duration(s.exposureMinutes)} of driving`];
                if (!s.enoughData) lines.push('Not enough driving to judge');
                else if (s.danger) lines.push(`⚠ Dangerous: ${num(s.ratio, 1)}× the average rate`);
                else if (s.ratio != null) lines.push(`${num(s.ratio, 1)}× the average rate`);
                return lines;
              },
            },
          },
        },
      },
    });
  }

  function slotTable(container, firstHeader, slots, nameOf) {
    container.replaceChildren(table(
      [{ label: firstHeader }, ...SEVERITIES.map((s) => ({ label: s, num: true })), { label: 'Total', num: true }, { label: 'Driving', num: true }, { label: 'Per driving hour', num: true }, { label: 'Note' }],
      slots.map((s) => ({
        flag: s.danger,
        cells: [nameOf(s), ...SEVERITIES.map((sev) => num(s[sev])), num(s.total), duration(s.exposureMinutes), s.rate == null ? '–' : num(s.rate, 2),
          s.danger ? `Dangerous (${num(s.ratio, 1)}×)` : s.enoughData ? '' : 'Not enough data'],
      })),
    ));
  }

  // ======================================
  // RENDER
  // ======================================
  function renderAll() {
    chartTheme();
    const o = overview;
    const t = o.totals;
    $('tz').textContent = tz === 'Africa/Johannesburg' ? 'South African time (SAST)' : tz;

    // ----- Empty state -----
    const notice = $('notice');
    if (t.sessions === 0) {
      notice.hidden = false;
      notice.textContent = state.includeDemo
        ? 'No drives recorded in this period.'
        : 'No drives recorded in this period yet. Tick “Include demo data” to see example data.';
    } else notice.hidden = true;

    // ----- KPIs -----
    $('kpi-events').textContent = num(t.events);
    const sevDetail = $('kpi-severity');
    sevDetail.replaceChildren(...SEVERITIES.map((sev) => {
      const b = sevBadge(sev);
      b.lastChild.textContent = ` ${sev} ${num(t.bySeverity[sev])}`;
      return b;
    }));
    $('kpi-hours').textContent = t.drivingHours == null ? '–' : `${num(t.drivingHours, 1)} h`;
    $('kpi-sessions').textContent = `${num(t.sessions)} drive${t.sessions === 1 ? '' : 's'}`;
    $('kpi-rate').textContent = t.eventsPerDrivingHour == null ? '–' : num(t.eventsPerDrivingHour, 2);
    $('kpi-first').textContent = duration(t.avgMinutesToFirstEvent);
    $('kpi-first-detail').textContent = t.sessions ? `${num((t.sessionsWithEvents / t.sessions) * 100)}% of drives had an event` : '';
    $('kpi-closure').textContent = t.longestClosureSeconds == null ? '–' : `${num(t.longestClosureSeconds, 1)} s`;

    // ----- Findings -----
    const br = o.breakRecommendation;
    $('break-main').textContent = br.minutes ? `Take a break every ${duration(br.minutes)}` : 'No recommendation yet';
    $('break-detail').textContent = br.message;

    $('danger-ratio').textContent = o.thresholds.dangerRatio;
    $('min-exposure').textContent = o.thresholds.minExposureMinutes;
    const list = $('danger-list');
    list.replaceChildren();
    if (o.dangerZones.length) {
      $('danger-intro').textContent = 'Time of day and drive length combinations with the highest fatigue rate:';
      for (const z of o.dangerZones) {
        list.append(el('li', {},
          el('span', { text: `${hourRange(z.hour)}, after ${z.driveLabel.replace('–', ' to ')} of driving: ` }),
          el('span', { class: 'ratio', text: `${num(z.ratio, 1)}× average` }),
          el('span', { class: 'muted', text: ` (${num(z.events)} events in ${duration(z.exposureMinutes)})` })));
      }
    } else {
      $('danger-intro').textContent = 'No combination stands out yet. More driving data is needed, or fatigue is spread evenly.';
    }

    // ----- Bar charts -----
    const measureText = state.measure === 'count' ? 'Number of fatigue events, by severity.' : 'Fatigue events per hour of driving. Red bars are dangerous.';
    $('hour-sub').textContent = `${measureText} Hour of day in ${tz === 'Africa/Johannesburg' ? 'SAST' : tz}.`;
    $('drive-sub').textContent = `${measureText} Minutes since the drive started.`;
    $('dow-sub').textContent = measureText;

    legendFor($('hour-legend'), state.measure);
    legendFor($('drive-legend'), state.measure);
    legendFor($('dow-legend'), state.measure);

    barChart('hour', $('hour-chart'), o.byHour.map((s) => String(s.hour).padStart(2, '0')), o.byHour, (s) => hourRange(s.hour));
    barChart('drive', $('drive-chart'), o.byDriveTime.map((s) => s.label), o.byDriveTime, (s) => `${s.label} into the drive`);
    barChart('dow', $('dow-chart'), o.byDayOfWeek.map((s) => s.day), o.byDayOfWeek, (s) => s.day);

    slotTable($('hour-table'), 'Hour', o.byHour, (s) => hourRange(s.hour));
    slotTable($('drive-table'), 'Time into drive', o.byDriveTime, (s) => s.label);
    slotTable($('dow-table'), 'Day', o.byDayOfWeek, (s) => s.day);

    renderHeatmap();
    renderHeartRate();
    renderRecent();
  }

  // ----- Heatmap -----
  const tip = el('div', { class: 'tip', role: 'tooltip' });
  tip.hidden = true;
  document.body.append(tip);
  function showTip(target, nodes) {
    tip.replaceChildren(...nodes);
    tip.hidden = false;
    const r = target.getBoundingClientRect();
    const w = tip.offsetWidth;
    const h = tip.offsetHeight;
    let x = r.left + r.width / 2 - w / 2;
    x = Math.max(8, Math.min(x, window.innerWidth - w - 8));
    const y = r.top - h - 8 < 8 ? r.bottom + 8 : r.top - h - 8;
    tip.style.left = `${x}px`;
    tip.style.top = `${y}px`;
  }
  const hideTip = () => { tip.hidden = true; };

  function renderHeatmap() {
    const { buckets, cells } = overview.heatmap;
    const steps = [1, 2, 3, 4, 5, 6, 7].map((i) => css(`--seq-${i}`));
    const maxRate = Math.max(0, ...cells.flat().filter((c) => c.enoughData).map((c) => c.rate || 0));
    const stepOf = (rate) => (maxRate > 0 ? Math.min(6, Math.floor((rate / maxRate) * 6.999)) : 0);

    // Scale legend
    const ramp = el('span', { class: 'ramp' }, ...steps.map((c) => { const i = el('i'); i.style.background = c; return i; }));
    $('heat-scale').replaceChildren(
      el('span', { text: '0' }), ramp, el('span', { text: `${num(maxRate, 1)} events per driving hour` }),
      el('span', { text: '·' }), el('span', { class: 'danger-key', text: '⚠' }), el('span', { text: 'dangerous' }),
      el('span', { text: '·' }), el('i', { class: 'nodata-key' }), el('span', { text: 'not enough data' }),
    );

    const grid = $('heatmap');
    grid.replaceChildren(el('div', { class: 'hd', text: 'Hour' }), ...buckets.map((b) => el('div', { class: 'hd', text: b.label })));
    cells.forEach((row, hour) => {
      grid.append(el('div', { class: 'rh', text: hourLabel(hour) }));
      row.forEach((c) => {
        const cell = el('div', { class: 'cell', tabindex: '0', role: 'gridcell' });
        const desc = `${hourRange(hour)}, ${buckets[c.bucket].label} into the drive: `
          + (c.enoughData ? `${num(c.rate, 2)} events per driving hour${c.danger ? ', dangerous' : ''}` : 'not enough data');
        cell.setAttribute('aria-label', desc);
        if (!c.enoughData) cell.classList.add('nodata');
        else {
          const s = stepOf(c.rate || 0);
          cell.style.background = steps[s];
          cell.classList.add(s >= 3 ? 'dark-ink' : 'light-ink');
          if (c.danger) cell.classList.add('danger');
        }
        const tipNodes = () => [
          el('div', {}, el('strong', { text: c.enoughData ? `${num(c.rate, 2)} / h` : 'Not enough data' })),
          el('div', { text: `${hourRange(hour)}, ${buckets[c.bucket].label} into the drive` }),
          el('div', { class: 'muted', text: `${num(c.total)} events in ${duration(c.exposureMinutes)} of driving` }),
          c.danger ? el('div', { text: `⚠ ${num(c.ratio, 1)}× the average rate` }) : null,
        ].filter(Boolean);
        cell.addEventListener('mouseenter', () => showTip(cell, tipNodes()));
        cell.addEventListener('focus', () => showTip(cell, tipNodes()));
        cell.addEventListener('mouseleave', hideTip);
        cell.addEventListener('blur', hideTip);
        grid.append(cell);
      });
    });

    $('heat-table').replaceChildren(table(
      [{ label: 'Hour' }, ...buckets.map((b) => ({ label: b.label, num: true }))],
      cells.map((row, hour) => ({
        cells: [hourRange(hour), ...row.map((c) => (c.enoughData ? `${num(c.rate, 2)}${c.danger ? ' ⚠' : ''}` : '–'))],
      })),
    ));
  }

  // ----- Heart-rate dot plot -----
  function renderHeartRate() {
    const hr = overview.heartRate;
    $('hr-message').textContent = hr.message;
    const box = $('hr-dotplot');
    box.replaceChildren();
    const rows = [
      { label: 'Normal driving', value: hr.normalAvg, color: css('--accent') },
      ...SEVERITIES.map((sev) => ({ label: `5 min before ${sev}`, value: hr.bySeverity[sev].avg, color: css(SEV_TOKEN[sev]), sev, count: hr.bySeverity[sev].count })),
      { label: 'At the event', value: hr.atEventAvg, color: css('--text-secondary') },
    ].filter((r) => r.value != null);
    if (rows.length < 2) return;

    const values = rows.map((r) => r.value);
    const lo = Math.floor((Math.min(...values) - 3) / 5) * 5;
    const hi = Math.ceil((Math.max(...values) + 3) / 5) * 5;
    const pos = (v) => `${((v - lo) / (hi - lo)) * 100}%`;

    for (const r of rows) {
      const track = el('div', { class: 'dot-track' });
      if (hr.normalAvg != null) { const ref = el('i', { class: 'ref' }); ref.style.left = pos(hr.normalAvg); track.append(ref); }
      const dot = el('i', { class: 'dot' });
      dot.style.left = pos(r.value);
      dot.style.background = r.color;
      track.append(dot);
      const label = el('span', { class: 'lbl' });
      if (r.sev) { label.innerHTML = sevIcon(r.sev); label.classList.add('sev'); }
      label.append(document.createTextNode(r.label));
      box.append(el('div', { class: 'dot-row' }, label, track, el('span', { class: 'val', text: `${num(r.value, 1)} bpm` })));
    }
    const ticks = el('div', { class: 'ticks' });
    for (let v = lo; v <= hi; v += (hi - lo) / 4) ticks.append(el('span', { text: num(v) }));
    box.append(el('div', { class: 'dot-axis' }, el('span'), ticks, el('span', { text: 'bpm' })));
  }

  // ----- Recent events -----
  function renderRecent() {
    const ev = overview.recentEvents;
    $('recent-table').replaceChildren(...(ev.length ? table(
      [{ label: 'Time' }, { label: 'Pilot' }, { label: 'Severity' }, { label: 'Into drive', num: true }, { label: 'Heart rate', num: true }, { label: 'Eye closure', num: true }],
      ev.map((e) => ({
        cells: [when(e.occurredAt), e.pilotId, sevBadge(e.severity), duration(e.driveMinutes),
          e.heartRateBpm == null ? '–' : `${num(e.heartRateBpm)} bpm`,
          e.closureSeconds == null ? '–' : `${num(e.closureSeconds, 1)} s`],
      })),
    ).childNodes : [el('caption', { class: 'muted', text: 'No fatigue events in this period.' })]));
  }

  // ----- Timeline -----
  function renderTimeline() {
    chartTheme();
    const { points, events } = timeline;
    const maxMin = Math.max(1, ...points.map((p) => p.minute), ...events.map((e) => e.minute));

    // Legend: event markers by severity
    const legend = $('timeline-legend');
    legend.replaceChildren(...SEVERITIES.map((sev) => {
      const k = el('i', { class: 'line-key' });
      k.style.background = css(SEV_TOKEN[sev]);
      k.style.width = '2px'; k.style.height = '12px';
      return el('span', {}, k, document.createTextNode(`${sev} event`));
    }));

    // Fatigue level strip
    const strip = $('level-strip');
    strip.replaceChildren();
    let run = null;
    const flush = (end) => {
      if (run && run.level && run.level !== 'normal') {
        const seg = el('i');
        seg.style.left = `${(run.start / maxMin) * 100}%`;
        seg.style.width = `${Math.max(0.4, ((end - run.start) / maxMin) * 100)}%`;
        seg.style.background = css(SEV_TOKEN[run.level]);
        seg.title = run.level;
        strip.append(seg);
      }
    };
    for (const p of points) {
      if (!run || run.level !== p.level) { flush(p.minute); run = { level: p.level, start: p.minute }; }
    }
    flush(maxMin);

    const lineChart = (key, canvas, field, label, dp) => replaceChart(key, canvas, {
      type: 'line',
      data: { datasets: [{
        label,
        data: points.filter((p) => p[field] != null).map((p) => ({ x: p.minute, y: p[field] })),
        borderColor: css('--accent'),
        backgroundColor: css('--accent'),
        borderWidth: 2,
        borderJoinStyle: 'round',
        borderCapStyle: 'round',
        pointRadius: 0,
        pointHoverRadius: 5,
        pointHoverBorderColor: css('--surface'),
        pointHoverBorderWidth: 2,
        tension: 0.2,
      }] },
      plugins: [markersPlugin],
      options: {
        maintainAspectRatio: false,
        layout: { padding: { right: 10 } },
        interaction: { mode: 'nearest', axis: 'x', intersect: false },
        scales: {
          x: axis({ type: 'linear', min: 0, max: maxMin, ticks: { color: css('--text-muted'), maxTicksLimit: 8, callback: (v) => shortDuration(v) } }),
          y: axis({ afterFit: (scale) => { scale.width = 56; }, ticks: { color: css('--text-muted'), maxTicksLimit: 4 }, title: { display: true, text: label, color: css('--text-secondary'), font: { size: 11 } } }),
        },
        plugins: {
          legend: { display: false },
          markers: { events },
          tooltip: {
            ...tooltipStyle(),
            displayColors: false,
            callbacks: {
              title: (items) => `${shortDuration(items[0].parsed.x)} into the drive`,
              label: (item) => `${label}: ${num(item.parsed.y, dp)}`,
            },
          },
        },
      },
    });

    lineChart('tlHr', $('tl-hr'), 'heartRateBpm', 'Heart rate (bpm)', 0);
    lineChart('tlBlink', $('tl-blink'), 'blinkRatePerMinute', 'Blinks / min', 0);
    lineChart('tlEar', $('tl-ear'), 'ear', 'Eye openness (EAR)', 2);
  }

  // ======================================
  // WIRING
  // ======================================
  function initControls() {
    const days = $('days');
    days.value = state.days;
    if (days.value !== state.days) days.value = '30';
    $('includeDemo').checked = state.includeDemo;
    document.querySelector(`input[name="measure"][value="${state.measure}"]`).checked = true;

    days.addEventListener('change', () => { state.days = days.value; store.set('days', state.days); refresh(); });
    $('includeDemo').addEventListener('change', (e) => { state.includeDemo = e.target.checked; store.set('includeDemo', String(state.includeDemo)); refresh(); });
    document.querySelectorAll('input[name="measure"]').forEach((r) => r.addEventListener('change', () => {
      state.measure = r.value; store.set('measure', state.measure);
      if (overview) renderAll();
    }));
    $('session-select').addEventListener('change', (e) => { state.sessionId = e.target.value; loadTimeline(); });
    $('filters').addEventListener('submit', (e) => e.preventDefault());

    // Redraw with the other palette when the OS theme changes.
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
      if (overview) renderAll();
      if (timeline) renderTimeline();
    });
    setInterval(() => { if (!document.hidden) refresh(); }, REFRESH_MS);
  }

  initControls();
  refresh();
})();
