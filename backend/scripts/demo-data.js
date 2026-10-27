#!/usr/bin/env node
// Fills the database with realistic fake drives so the dashboard has something
// to show, or removes them again. Demo sessions are marked isDemo: true; their
// readings and events are removed with them. Real data is never touched.
//
//   npm run demo:add                      (4 weeks of drives, local database from .env)
//   npm run demo:add -- --days 14
//   npm run demo:remove
//   npm run demo:add -- --uri "mongodb+srv://..."   (another database, e.g. Atlas)
//
// Built-in patterns (so the dashboard has something to find): fatigue rises
// after ~1 h of driving and peaks in the early morning (02:00-05:00) and the
// afternoon dip (13:00-16:00); heart rate drops and blinking rises in the
// minutes before an event.
require('dotenv').config();
const mongoose = require('mongoose');
const MonitoringSession = require('../src/models/MonitoringSession');
const SensorReading = require('../src/models/SensorReading');
const FatigueEvent = require('../src/models/FatigueEvent');

const args = process.argv.slice(2);
const arg = (name) => { const i = args.indexOf(name); return i > -1 ? args[i + 1] : undefined; };
const command = args[0];
const URI = arg('--uri') || process.env.MONGODB_URI;
const DAYS = Number(arg('--days') || 28);

const UTC_OFFSET_H = 2; // South Africa (no daylight saving)
const READING_EVERY_S = 30;
const PILOTS = [
  { id: 'demo-pilot-01', hr: 66 },
  { id: 'demo-pilot-02', hr: 72 },
  { id: 'demo-pilot-03', hr: 78 },
];

// Seeded random numbers, so every run produces the same demo data.
let seed = 381;
function rand() {
  seed = (seed + 0x6d2b79f5) | 0;
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const between = (a, b) => a + rand() * (b - a);
const pick = (xs) => xs[Math.floor(rand() * xs.length)];
const noise = (size) => (rand() + rand() + rand() - 1.5) * size;

// ======================================
// FATIGUE MODEL
// ======================================

// Relative risk by local hour of day (circadian dips).
function hourRisk(h) {
  if (h >= 2 && h < 5) return 3.2;
  if (h >= 22 || h < 2) return 2.0;
  if (h >= 13 && h < 16) return 1.9;
  if (h >= 5 && h < 7) return 1.5;
  return 1;
}

// Relative risk by minutes into the drive: flat for the first hour, then rising.
const driveRisk = (min) => (min < 60 ? 1 : 1 + ((min - 60) / 60) * 0.9);

const BASE_EVENTS_PER_MIN = 0.012; // ~0.7 events per hour when fresh

function startHour() {
  const r = rand();
  if (r < 0.35) return between(5, 9); // morning
  if (r < 0.65) return between(11, 15); // midday / afternoon
  if (r < 0.85) return between(16, 20); // evening
  return (between(21, 27)) % 24; // night
}

function driveMinutes(hour) {
  const night = hour >= 21 || hour < 4;
  const long = rand() < (night ? 0.6 : 0.3);
  return Math.round(long ? between(120, 260) : between(25, 120));
}

function makeDrive(pilot, start, minutes) {
  const startMs = start.getTime();
  const localHour = (ms) => new Date(ms + UTC_OFFSET_H * 3600000).getUTCHours();

  // ----- Events (minute by minute) -----
  const events = [];
  let cooldownUntil = 0;
  for (let m = 1; m < minutes; m += 1) {
    if (m < cooldownUntil) continue;
    const t = startMs + m * 60000;
    const risk = hourRisk(localHour(t)) * driveRisk(m);
    if (rand() >= BASE_EVENTS_PER_MIN * risk) continue;

    const severe = rand() * risk;
    const severity = severe > 4 ? 'Critical' : severe > 1.8 ? 'High' : 'Warning';
    const closure = { Warning: between(0.7, 1.2), High: between(1.2, 2), Critical: between(2, 4) }[severity];
    events.push({ t: t + Math.round(between(0, 59000)), severity, closureSeconds: Math.round(closure * 10) / 10 });
    cooldownUntil = m + 3;
  }

  // ----- Readings (every 30 s) -----
  const readings = [];
  for (let s = 0; s <= minutes * 60; s += READING_EVERY_S) {
    const t = startMs + s * 1000;
    const driveH = s / 3600;
    // Closeness to the next event (1 = event now, 0 = 5+ min away)
    const next = events.find((e) => e.t >= t);
    const pre = next ? Math.max(0, 1 - (next.t - t) / 300000) : 0;
    // Level stays raised for 60 s after an event
    const recent = [...events].reverse().find((e) => e.t <= t && t - e.t < 60000);

    readings.push({
      recordedAt: new Date(t),
      heartRateBpm: Math.round(pilot.hr - driveH * 1.5 - pre * 7 + noise(3)),
      blinkRatePerMinute: Math.round(between(13, 18) + driveH * 1.5 + pre * 12),
      ear: Math.round(Math.min(0.34, Math.max(0.12, 0.3 - pre * 0.08 + noise(0.015))) * 1000) / 1000,
      fatigueLevel: recent ? recent.severity.toLowerCase() : 'normal',
      source: 'demo_data',
    });
  }

  // Pilot's state at each event = the nearest reading
  const eventDocs = events.map((e) => {
    const r = readings.reduce((best, x) =>
      Math.abs(x.recordedAt - e.t) < Math.abs(best.recordedAt - e.t) ? x : best);
    return {
      severity: e.severity,
      fatigueLevel: e.severity.toLowerCase(),
      message: `Fatigue level rose to ${e.severity.toUpperCase()}`,
      occurredAt: new Date(e.t),
      heartRateBpm: r.heartRateBpm - 2,
      blinkRatePerMinute: r.blinkRatePerMinute,
      ear: Math.max(0.1, r.ear - 0.06),
      closureSeconds: e.closureSeconds,
    };
  });

  return { readings, events: eventDocs };
}

// ======================================
// COMMANDS
// ======================================

async function add() {
  const now = Date.now();
  let sessions = 0;
  let readingCount = 0;
  let eventCount = 0;

  for (let d = DAYS; d >= 1; d -= 1) {
    const day = new Date(now - d * 86400000);
    const drivesToday = Math.round(between(1.5, 4));
    for (let i = 0; i < drivesToday; i += 1) {
      const hour = startHour();
      const dayStartUtc = Date.UTC(day.getUTCFullYear(), day.getUTCMonth(), day.getUTCDate()) - UTC_OFFSET_H * 3600000;
      const start = new Date(dayStartUtc + hour * 3600000);
      const minutes = driveMinutes(hour);
      if (start.getTime() + minutes * 60000 > now) continue;

      const pilot = pick(PILOTS);
      const { readings, events } = makeDrive(pilot, start, minutes);
      const session = await MonitoringSession.create({
        pilotId: pilot.id,
        notes: 'Demo data (npm run demo:remove deletes it)',
        status: 'ended',
        autopilotStatus: 'off',
        startedAt: start,
        endedAt: new Date(start.getTime() + minutes * 60000),
        isDemo: true,
      });
      await SensorReading.insertMany(readings.map((r) => ({ ...r, sessionId: session._id })), { ordered: false });
      if (events.length) {
        await FatigueEvent.insertMany(events.map((e) => ({ ...e, sessionId: session._id })), { ordered: false });
      }
      sessions += 1;
      readingCount += readings.length;
      eventCount += events.length;
      process.stdout.write(`\r${sessions} drives, ${readingCount} readings, ${eventCount} events`);
    }
  }
  console.log('\nDemo data added. Tick "Include demo data" on the dashboard to see it.');
}

async function remove() {
  const ids = (await MonitoringSession.find({ isDemo: true }).select('_id').lean()).map((s) => s._id);
  const [r, e, s] = await Promise.all([
    SensorReading.deleteMany({ sessionId: { $in: ids } }),
    FatigueEvent.deleteMany({ sessionId: { $in: ids } }),
    MonitoringSession.deleteMany({ _id: { $in: ids } }),
  ]);
  console.log(`Removed ${s.deletedCount} demo drives, ${r.deletedCount} readings, ${e.deletedCount} events.`);
}

(async () => {
  if (!['add', 'remove'].includes(command)) {
    console.log('Usage: node scripts/demo-data.js add|remove [--days 28] [--uri mongodb://...]');
    process.exit(1);
  }
  if (!URI) throw new Error('MONGODB_URI is missing. Set it in .env or pass --uri.');
  await mongoose.connect(URI);
  console.log(`Connected to ${mongoose.connection.host}/${mongoose.connection.name}`);
  if (command === 'add') await add(); else await remove();
  await mongoose.disconnect();
})().catch(async (e) => {
  console.error('Demo data failed:', e.message);
  await mongoose.disconnect().catch(() => {});
  process.exit(1);
});
