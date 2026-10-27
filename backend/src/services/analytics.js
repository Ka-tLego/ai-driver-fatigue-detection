// Dashboard analytics.
//
// "Dangerous" is measured as fatigue events per hour of driving (a rate), not
// raw counts: if most driving happens at 14:00, most events will too, even if
// 14:00 is not especially risky. Driving time ("exposure") is counted in
// minutes that have at least one sensor reading, so pauses are not counted.
//
// buildOverview() is pure (plain data in, plain data out) so it can be tested
// without a database; loadOverview() fetches the data for it.

const LEVELS = ['normal', 'warning', 'high', 'critical'];
const SEVERITIES = ['Warning', 'High', 'Critical'];
const DAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

const DRIVE_BUCKET_MIN = 15; // "time into the drive" chart: 15-minute groups
const DRIVE_BUCKETS = 17; // 0-15 ... 3h45-4h, then 4h+
const HEAT_BUCKET_MIN = 30; // heatmap columns: 30-minute groups
const HEAT_BUCKETS = 7; // 0-30 ... 2h30-3h, then 3h+
const MIN_EXPOSURE_MIN = 60; // a slot needs >= 1 h of driving before it can be judged
const DANGER_RATIO = 1.5; // dangerous = >= 1.5x the overall event rate
const PRE_EVENT_MS = 5 * 60 * 1000; // heart-rate window before an event

// ======================================
// HELPERS
// ======================================

function durationLabel(min) {
  const h = Math.floor(min / 60);
  const m = min % 60;
  if (h === 0) return `${m}m`;
  return m === 0 ? `${h}h` : `${h}h${String(m).padStart(2, '0')}`;
}

function bucketDefs(size, count) {
  return Array.from({ length: count }, (_, i) => {
    const startMin = i * size;
    const last = i === count - 1;
    return {
      startMin,
      endMin: last ? null : startMin + size,
      label: last ? `${durationLabel(startMin)}+` : `${durationLabel(startMin)}–${durationLabel(startMin + size)}`,
    };
  });
}

/** Returns date -> { hour, dow } in the given time zone (dow 0 = Monday). */
function localClock(tz) {
  const fmt = new Intl.DateTimeFormat('en-GB', { timeZone: tz, hour: '2-digit', hourCycle: 'h23', weekday: 'short' });
  const cache = new Map();
  return (date) => {
    const key = Math.floor(date.getTime() / 900000); // 15-min slots handle :30/:45 offsets
    let v = cache.get(key);
    if (!v) {
      const parts = Object.fromEntries(fmt.formatToParts(date).map((p) => [p.type, p.value]));
      v = { hour: Number(parts.hour) % 24, dow: DAYS.indexOf(parts.weekday) };
      cache.set(key, v);
    }
    return v;
  };
}

const round = (n, dp = 2) => (n == null || !Number.isFinite(n) ? null : Math.round(n * 10 ** dp) / 10 ** dp);
const avg = (xs) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);
const emptyCounts = () => ({ Warning: 0, High: 0, Critical: 0, total: 0, exposureMinutes: 0 });

function finishSlot(slot, overallRate) {
  const enoughData = slot.exposureMinutes >= MIN_EXPOSURE_MIN;
  const rate = slot.exposureMinutes > 0 ? slot.total / (slot.exposureMinutes / 60) : null;
  return {
    ...slot,
    rate: round(rate),
    ratio: rate != null && overallRate > 0 ? round(rate / overallRate) : null,
    enoughData,
    danger: enoughData && slot.total >= 2 && overallRate > 0 && rate >= DANGER_RATIO * overallRate,
  };
}

// ======================================
// PURE CALCULATION
// ======================================

/**
 * @param sessions      [{ _id, startedAt, pilotId }]
 * @param events        [{ _id, sessionId, severity, occurredAt, heartRateBpm?, closureSeconds?, ... }]
 * @param activeMinutes [{ sessionId, minute }]  one row per minute with readings
 * @param heartRate     { normalAvg, normalCount, preEvent: [{ severity, preHr }] }
 */
function buildOverview({ sessions, events, activeMinutes, heartRate = {}, tz }) {
  const clock = localClock(tz);
  const sessionById = new Map(sessions.map((s) => [String(s._id), s]));
  const driveBuckets = bucketDefs(DRIVE_BUCKET_MIN, DRIVE_BUCKETS);
  const heatBuckets = bucketDefs(HEAT_BUCKET_MIN, HEAT_BUCKETS);

  const byHour = Array.from({ length: 24 }, (_, hour) => ({ hour, ...emptyCounts() }));
  const byDrive = driveBuckets.map((b) => ({ ...b, ...emptyCounts() }));
  const byDow = DAYS.map((day) => ({ day, ...emptyCounts() }));
  const heat = byHour.map(() => heatBuckets.map(() => ({ total: 0, exposureMinutes: 0 })));

  const driveIndex = (min, size, count) => Math.min(count - 1, Math.max(0, Math.floor(min / size)));
  const minutesSinceStart = (session, date) =>
    Math.max(0, (new Date(date) - new Date(session.startedAt)) / 60000);

  // ----- Exposure (driving minutes) -----
  let exposureMinutes = 0;
  for (const row of activeMinutes) {
    const session = sessionById.get(String(row.sessionId));
    if (!session) continue;
    const minute = new Date(row.minute);
    const drive = minutesSinceStart(session, minute);
    const { hour, dow } = clock(minute);
    exposureMinutes += 1;
    byHour[hour].exposureMinutes += 1;
    byDow[dow].exposureMinutes += 1;
    byDrive[driveIndex(drive, DRIVE_BUCKET_MIN, DRIVE_BUCKETS)].exposureMinutes += 1;
    heat[hour][driveIndex(drive, HEAT_BUCKET_MIN, HEAT_BUCKETS)].exposureMinutes += 1;
  }

  // ----- Events -----
  const bySeverity = { Warning: 0, High: 0, Critical: 0 };
  const firstEventMin = new Map(); // sessionId -> minutes to first event
  const counted = [];
  for (const e of events) {
    const session = sessionById.get(String(e.sessionId));
    if (!session || !SEVERITIES.includes(e.severity)) continue;
    const occurredAt = new Date(e.occurredAt);
    const drive = minutesSinceStart(session, occurredAt);
    const { hour, dow } = clock(occurredAt);
    const sev = e.severity;

    bySeverity[sev] += 1;
    for (const slot of [byHour[hour], byDow[dow], byDrive[driveIndex(drive, DRIVE_BUCKET_MIN, DRIVE_BUCKETS)]]) {
      slot[sev] += 1;
      slot.total += 1;
    }
    heat[hour][driveIndex(drive, HEAT_BUCKET_MIN, HEAT_BUCKETS)].total += 1;

    const key = String(e.sessionId);
    firstEventMin.set(key, Math.min(firstEventMin.get(key) ?? Infinity, drive));
    counted.push({ ...e, occurredAt, driveMinutes: drive, pilotId: session.pilotId });
  }

  const totalEvents = counted.length;
  const drivingHours = exposureMinutes / 60;
  const overallRate = drivingHours > 0 ? totalEvents / drivingHours : 0;

  const hours = byHour.map((s) => finishSlot(s, overallRate));
  const drive = byDrive.map((s) => finishSlot(s, overallRate));
  const days = byDow.map((s) => finishSlot(s, overallRate));
  const cells = heat.map((row, hour) =>
    row.map((cell, b) => ({ hour, bucket: b, ...finishSlot(cell, overallRate) })),
  );

  const dangerZones = cells
    .flat()
    .filter((c) => c.danger)
    .sort((a, b) => b.rate - a.rate)
    .slice(0, 5)
    .map((c) => ({
      hour: c.hour,
      driveLabel: heatBuckets[c.bucket].label,
      rate: c.rate,
      ratio: c.ratio,
      events: c.total,
      exposureMinutes: c.exposureMinutes,
    }));

  const longest = counted.reduce((m, e) => Math.max(m, e.closureSeconds || 0), 0);

  return {
    timezone: tz,
    thresholds: { minExposureMinutes: MIN_EXPOSURE_MIN, dangerRatio: DANGER_RATIO },
    totals: {
      events: totalEvents,
      bySeverity,
      sessions: sessions.length,
      sessionsWithEvents: firstEventMin.size,
      drivingHours: round(drivingHours, 1),
      eventsPerDrivingHour: round(overallRate),
      avgMinutesToFirstEvent: round(avg([...firstEventMin.values()]), 0),
      longestClosureSeconds: longest > 0 ? round(longest, 1) : null,
    },
    byHour: hours,
    byDriveTime: drive,
    byDayOfWeek: days,
    heatmap: { buckets: heatBuckets, cells },
    dangerZones,
    breakRecommendation: recommendBreak(drive, overallRate, drivingHours),
    heartRate: summariseHeartRate(heartRate, counted),
    recentEvents: counted
      .sort((a, b) => b.occurredAt - a.occurredAt)
      .slice(0, 15)
      .map((e) => ({
        id: e._id,
        sessionId: e.sessionId,
        pilotId: e.pilotId,
        severity: e.severity,
        occurredAt: e.occurredAt,
        driveMinutes: round(e.driveMinutes, 0),
        heartRateBpm: e.heartRateBpm ?? null,
        closureSeconds: e.closureSeconds ?? null,
      })),
  };
}

/** Finds the drive time after which the event rate clearly rises. */
function recommendBreak(drive, overallRate, drivingHours) {
  if (drivingHours < 3 || overallRate === 0) {
    return { minutes: null, message: 'Not enough driving data yet to recommend a break interval.' };
  }

  // Baseline = the first hour of driving (buckets 0-3), if there's enough of it.
  const first = drive.slice(0, 4);
  const firstExposure = first.reduce((a, s) => a + s.exposureMinutes, 0);
  const firstEvents = first.reduce((a, s) => a + s.total, 0);
  const baseline = firstExposure >= MIN_EXPOSURE_MIN && firstEvents > 0
    ? firstEvents / (firstExposure / 60)
    : overallRate;

  for (let i = 4; i < drive.length; i += 1) {
    const s = drive[i];
    if (!s.enoughData || s.rate < DANGER_RATIO * baseline) continue;
    // Must stay elevated in the next group too (when there's data), not a one-off spike.
    const next = drive[i + 1];
    if (next && next.enoughData && next.rate < baseline) continue;

    const riskAfter = s.startMin;
    const minutes = Math.max(30, riskAfter - 15);
    const ratio = round(s.rate / baseline, 1);
    return {
      minutes,
      riskRisesAfterMinutes: riskAfter,
      ratio,
      message: `Fatigue events are ${ratio}× more frequent from ${durationLabel(riskAfter)} of driving onwards. `
        + `Take a break at least every ${durationLabel(minutes)}.`,
    };
  }
  return { minutes: null, message: 'No clear rise in fatigue with driving time yet.' };
}

function summariseHeartRate({ normalAvg = null, normalCount = 0, preEvent = [] }, events) {
  const withHr = preEvent.filter((p) => p.preHr != null);
  const preEventAvg = avg(withHr.map((p) => p.preHr));
  const bySeverity = Object.fromEntries(SEVERITIES.map((sev) => {
    const xs = withHr.filter((p) => p.severity === sev).map((p) => p.preHr);
    return [sev, { avg: round(avg(xs), 1), count: xs.length }];
  }));
  const atEvent = events.map((e) => e.heartRateBpm).filter((x) => typeof x === 'number');
  const difference = preEventAvg != null && normalAvg != null ? preEventAvg - normalAvg : null;

  let message = 'Not enough heart-rate data yet. Wear the HR strap while driving.';
  if (withHr.length >= 5 && normalCount >= 30) {
    message = Math.abs(difference) < 2
      ? 'No clear heart-rate change before fatigue events.'
      : `Heart rate averages ${round(Math.abs(difference), 1)} bpm ${difference < 0 ? 'lower' : 'higher'} `
        + 'in the 5 minutes before a fatigue event than during normal driving.';
  }
  return {
    normalAvg: round(normalAvg, 1),
    preEventAvg: round(preEventAvg, 1),
    atEventAvg: round(avg(atEvent), 1),
    difference: round(difference, 1),
    eventsWithHr: withHr.length,
    bySeverity,
    message,
  };
}

// ======================================
// DATABASE LOADING
// ======================================

function sessionFilter({ days, includeDemo, now = new Date() }) {
  const filter = {};
  if (days) filter.startedAt = { $gte: new Date(now.getTime() - days * 86400000) };
  if (!includeDemo) filter.isDemo = { $ne: true };
  return filter;
}

async function loadOverview({ days, includeDemo, tz }) {
  const MonitoringSession = require('../models/MonitoringSession');
  const SensorReading = require('../models/SensorReading');
  const FatigueEvent = require('../models/FatigueEvent');

  const sessions = await MonitoringSession.find(sessionFilter({ days, includeDemo }))
    .select('startedAt pilotId').lean();
  const ids = sessions.map((s) => s._id);

  const [events, activeMinutes, normalHr, preEvent] = await Promise.all([
    FatigueEvent.find({ sessionId: { $in: ids } }).lean(),
    SensorReading.aggregate([
      { $match: { sessionId: { $in: ids } } },
      { $group: { _id: { s: '$sessionId', m: { $dateTrunc: { date: '$recordedAt', unit: 'minute' } } } } },
      { $project: { _id: 0, sessionId: '$_id.s', minute: '$_id.m' } },
    ]),
    SensorReading.aggregate([
      { $match: { sessionId: { $in: ids }, fatigueLevel: 'normal', heartRateBpm: { $ne: null } } },
      { $group: { _id: null, avg: { $avg: '$heartRateBpm' }, count: { $sum: 1 } } },
    ]),
    FatigueEvent.aggregate([
      { $match: { sessionId: { $in: ids } } },
      {
        $lookup: {
          from: SensorReading.collection.name,
          let: { s: '$sessionId', t: '$occurredAt' },
          pipeline: [
            {
              $match: {
                $expr: {
                  $and: [
                    { $eq: ['$sessionId', '$$s'] },
                    { $gte: ['$recordedAt', { $subtract: ['$$t', PRE_EVENT_MS] }] },
                    { $lt: ['$recordedAt', '$$t'] },
                  ],
                },
              },
            },
            { $match: { heartRateBpm: { $ne: null } } },
            { $group: { _id: null, hr: { $avg: '$heartRateBpm' } } },
          ],
          as: 'pre',
        },
      },
      { $project: { _id: 0, severity: 1, preHr: { $first: '$pre.hr' } } },
    ]),
  ]);

  return buildOverview({
    sessions,
    events,
    activeMinutes,
    heartRate: { normalAvg: normalHr[0]?.avg ?? null, normalCount: normalHr[0]?.count ?? 0, preEvent },
    tz,
  });
}

async function loadSessionList({ days, includeDemo, limit = 50 }) {
  const MonitoringSession = require('../models/MonitoringSession');
  const SensorReading = require('../models/SensorReading');
  const FatigueEvent = require('../models/FatigueEvent');

  const sessions = await MonitoringSession.find(sessionFilter({ days, includeDemo }))
    .sort({ startedAt: -1 }).limit(limit).select('startedAt pilotId isDemo').lean();
  const ids = sessions.map((s) => s._id);
  const [readings, events] = await Promise.all([
    SensorReading.aggregate([
      { $match: { sessionId: { $in: ids } } },
      { $group: { _id: '$sessionId', last: { $max: '$recordedAt' } } },
    ]),
    FatigueEvent.aggregate([
      { $match: { sessionId: { $in: ids } } },
      { $group: { _id: '$sessionId', count: { $sum: 1 }, severities: { $addToSet: '$severity' } } },
    ]),
  ]);
  const lastBy = new Map(readings.map((r) => [String(r._id), r.last]));
  const eventsBy = new Map(events.map((e) => [String(e._id), e]));

  return sessions.map((s) => {
    const last = lastBy.get(String(s._id));
    const ev = eventsBy.get(String(s._id));
    const peak = ev ? [...SEVERITIES].reverse().find((sev) => ev.severities.includes(sev)) : null;
    return {
      id: s._id,
      pilotId: s.pilotId,
      isDemo: !!s.isDemo,
      startedAt: s.startedAt,
      durationMinutes: last ? Math.max(0, Math.round((new Date(last) - new Date(s.startedAt)) / 60000)) : 0,
      events: ev ? ev.count : 0,
      peakSeverity: peak,
    };
  });
}

/** Readings for one session, averaged into at most ~400 points, plus its events. */
async function loadTimeline(sessionId) {
  const MonitoringSession = require('../models/MonitoringSession');
  const SensorReading = require('../models/SensorReading');
  const FatigueEvent = require('../models/FatigueEvent');

  const session = await MonitoringSession.findById(sessionId).lean();
  if (!session) return null;

  const [range] = await SensorReading.aggregate([
    { $match: { sessionId: session._id } },
    { $group: { _id: null, first: { $min: '$recordedAt' }, last: { $max: '$recordedAt' } } },
  ]);
  const durationSec = range ? (range.last - range.first) / 1000 : 0;
  const binSize = Math.max(10, Math.ceil(durationSec / 400));

  const [points, events] = await Promise.all([
    SensorReading.aggregate([
      { $match: { sessionId: session._id } },
      {
        $group: {
          _id: { $dateTrunc: { date: '$recordedAt', unit: 'second', binSize } },
          heartRateBpm: { $avg: '$heartRateBpm' },
          blinkRatePerMinute: { $avg: '$blinkRatePerMinute' },
          ear: { $avg: '$ear' },
          level: { $max: { $indexOfArray: [LEVELS, '$fatigueLevel'] } },
        },
      },
      { $sort: { _id: 1 } },
    ]),
    FatigueEvent.find({ sessionId: session._id }).sort({ occurredAt: 1 }).lean(),
  ]);

  const minutesIn = (d) => round(Math.max(0, (new Date(d) - new Date(session.startedAt)) / 60000), 2);
  return {
    session: { id: session._id, pilotId: session.pilotId, startedAt: session.startedAt, isDemo: !!session.isDemo },
    binSeconds: binSize,
    points: points.map((p) => ({
      t: p._id,
      minute: minutesIn(p._id),
      heartRateBpm: round(p.heartRateBpm, 1),
      blinkRatePerMinute: round(p.blinkRatePerMinute, 1),
      ear: round(p.ear, 3),
      level: p.level >= 0 ? LEVELS[p.level] : null,
    })),
    events: events.map((e) => ({
      id: e._id,
      severity: e.severity,
      occurredAt: e.occurredAt,
      minute: minutesIn(e.occurredAt),
      heartRateBpm: e.heartRateBpm ?? null,
      closureSeconds: e.closureSeconds ?? null,
    })),
  };
}

module.exports = {
  buildOverview,
  loadOverview,
  loadSessionList,
  loadTimeline,
  constants: { DRIVE_BUCKET_MIN, HEAT_BUCKET_MIN, MIN_EXPOSURE_MIN, DANGER_RATIO },
};
