#!/usr/bin/env node
// Posts sample data to a running backend so you can check storage end to end
// (this stands in for the Flutter app). Usage: npm run seed [-- --url http://localhost:3000/api]
const i = process.argv.indexOf('--url');
const BASE = (i > -1 ? process.argv[i + 1] : process.env.API_BASE_URL || 'http://localhost:3000/api').replace(/\/+$/, '');

async function call(path, method = 'GET', body) {
  const res = await fetch(BASE + path, { method, headers: { 'Content-Type': 'application/json' }, body: body && JSON.stringify(body) });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status}: ${json.message}`);
  return json;
}

(async () => {
  await call('/health');
  const { data: s } = await call('/sessions', 'POST', { pilotId: 'pilot-seed', notes: 'seed data' });
  console.log('Session created:', s._id);
  await call(`/sessions/${s._id}`, 'PATCH', { autopilotStatus: 'on' });
  const rows = [
    { heartRateBpm: 78, blinkRatePerMinute: 16, ear: 0.31, fatigueLevel: 'normal' },
    { heartRateBpm: 66, blinkRatePerMinute: 24, ear: 0.24, fatigueLevel: 'warning' },
    { heartRateBpm: 58, blinkRatePerMinute: 30, ear: 0.19, fatigueLevel: 'high' },
    { heartRateBpm: 52, blinkRatePerMinute: 36, ear: 0.12, fatigueLevel: 'critical' },
  ];
  for (const r of rows) {
    await call(`/sessions/${s._id}/readings`, 'POST', r);
    if (r.fatigueLevel !== 'normal') {
      const severity = r.fatigueLevel[0].toUpperCase() + r.fatigueLevel.slice(1);
      await call('/events', 'POST', { sessionId: s._id, severity, fatigueLevel: r.fatigueLevel, message: `Seed ${severity} event` });
    }
  }
  await call(`/sessions/${s._id}`, 'PATCH', { status: 'paused' });
  await call(`/sessions/${s._id}`, 'PATCH', { status: 'active' });
  await call(`/sessions/${s._id}`, 'PATCH', { status: 'ended' });
  const { data } = await call(`/sessions/${s._id}/summary`);
  console.log(JSON.stringify(data, null, 2));
  console.log(`\nOpen in browser: ${BASE}/sessions/${s._id}`);
})().catch((e) => { console.error('Seed failed:', e.message); process.exit(1); });
