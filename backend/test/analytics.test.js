// Tests for the dashboard calculations (pure function, no database).
const test = require('node:test');
const assert = require('node:assert/strict');
const { buildOverview } = require('../src/services/analytics');

const TZ = 'Africa/Johannesburg'; // UTC+2
const MIN = 60000;

// One session per entry, with a reading every minute for `minutes`.
function fixture(drives) {
  const sessions = [];
  const activeMinutes = [];
  const events = [];
  drives.forEach((d, i) => {
    const id = `s${i}`;
    const start = new Date(d.start);
    sessions.push({ _id: id, startedAt: start, pilotId: 'p1' });
    for (let m = 0; m < d.minutes; m += 1) activeMinutes.push({ sessionId: id, minute: new Date(start.getTime() + m * MIN) });
    (d.events || []).forEach(([atMin, severity, extra], k) => events.push({
      _id: `${id}e${k}`, sessionId: id, severity, occurredAt: new Date(start.getTime() + atMin * MIN), ...extra,
    }));
  });
  return { sessions, activeMinutes, events, tz: TZ };
}

test('counts events by severity, hour of day (local time) and time into the drive', () => {
  // 08:00 SAST = 06:00 UTC
  const o = buildOverview(fixture([
    { start: '2026-10-05T06:00:00Z', minutes: 120, events: [[10, 'Warning'], [100, 'Critical', { closureSeconds: 2.5 }]] },
  ]));
  assert.equal(o.totals.events, 2);
  assert.deepEqual(o.totals.bySeverity, { Warning: 1, High: 0, Critical: 1 });
  assert.equal(o.totals.drivingHours, 2);
  assert.equal(o.totals.eventsPerDrivingHour, 1);
  assert.equal(o.totals.avgMinutesToFirstEvent, 10);
  assert.equal(o.totals.longestClosureSeconds, 2.5);
  assert.equal(o.byHour[8].Warning, 1); // 08:10 local
  assert.equal(o.byHour[9].Critical, 1); // 09:40 local
  assert.equal(o.byHour[8].exposureMinutes, 60);
  assert.equal(o.byDriveTime[0].Warning, 1); // 0-15 min
  assert.equal(o.byDriveTime[6].Critical, 1); // 1h30-1h45
  assert.equal(o.byDayOfWeek[0].total, 2); // Monday 5 Oct 2026
  assert.equal(o.recentEvents[0].severity, 'Critical');
});

test('flags danger by rate, not raw count, and needs enough driving to judge', () => {
  const drives = [];
  // Ten 4-hour drives starting 06:00 SAST: few events early, many after 3 h.
  for (let d = 0; d < 10; d += 1) {
    drives.push({
      start: `2026-10-${String(5 + d).padStart(2, '0')}T04:00:00Z`,
      minutes: 240,
      events: [[20, 'Warning'], [190, 'High'], [200, 'High'], [215, 'Warning'], [230, 'Critical']],
    });
  }
  // A short 30-minute drive at 23:00 with one event: too little driving to judge.
  drives.push({ start: '2026-10-20T21:00:00Z', minutes: 30, events: [[5, 'Warning']] });

  const o = buildOverview(fixture(drives));
  const lateDrive = o.byDriveTime.find((b) => b.label === '3h–3h15');
  assert.ok(lateDrive.danger, 'events after 3 h should be dangerous');
  assert.equal(o.byDriveTime[0].danger, false);
  assert.equal(o.byHour[23].enoughData, false);
  assert.equal(o.byHour[23].danger, false);
  assert.ok(o.dangerZones.length > 0);
  assert.equal(o.dangerZones[0].driveLabel, '3h+');

  assert.equal(o.breakRecommendation.riskRisesAfterMinutes, 180);
  assert.equal(o.breakRecommendation.minutes, 165);
  assert.match(o.breakRecommendation.message, /3h of driving/);
});

test('no data gives empty results without errors', () => {
  const o = buildOverview({ sessions: [], events: [], activeMinutes: [], tz: TZ });
  assert.equal(o.totals.events, 0);
  assert.equal(o.totals.eventsPerDrivingHour, 0);
  assert.equal(o.breakRecommendation.minutes, null);
  assert.equal(o.dangerZones.length, 0);
  assert.match(o.heartRate.message, /Not enough heart-rate data/);
});

test('heart rate summary compares the 5 minutes before events with normal driving', () => {
  const preEvent = Array.from({ length: 6 }, (_, i) => ({ severity: i < 3 ? 'Warning' : 'High', preHr: 64 }));
  const o = buildOverview({ sessions: [], events: [], activeMinutes: [], tz: TZ, heartRate: { normalAvg: 70, normalCount: 100, preEvent } });
  assert.equal(o.heartRate.difference, -6);
  assert.equal(o.heartRate.bySeverity.High.count, 3);
  assert.match(o.heartRate.message, /6 bpm lower/);
});

test('limits for the app: break interval, danger zones with drive-time bounds, UTC offset', () => {
  const { limitsFromOverview, utcOffsetMinutes } = require('../src/services/analytics');
  const drives = [];
  for (let d = 0; d < 10; d += 1) {
    drives.push({
      start: `2026-10-${String(5 + d).padStart(2, '0')}T04:00:00Z`,
      minutes: 240,
      events: [[20, 'Warning'], [190, 'High'], [200, 'High'], [215, 'Warning'], [230, 'Critical']],
    });
  }
  const limits = limitsFromOverview(buildOverview(fixture(drives)), new Date('2026-10-28T10:00:00Z'));
  assert.equal(limits.utcOffsetMinutes, 120);
  assert.equal(limits.breakEveryMinutes, 165);
  assert.ok(limits.dangerZones.length > 0);
  const z = limits.dangerZones[0];
  assert.equal(z.driveStartMin, 180);
  assert.equal(z.driveEndMin, null);
  assert.match(z.label, /^\d\d:00–\d\d:00 after 3h\+ of driving$/);
  assert.equal(utcOffsetMinutes('UTC'), 0);
});
