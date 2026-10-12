const express = require('express');
const mongoose = require('mongoose');
const MonitoringSession = require('../models/MonitoringSession');
const SensorReading = require('../models/SensorReading');
const FatigueEvent = require('../models/FatigueEvent');

const LEVELS = ['normal', 'warning', 'high', 'critical'];
const levelRank = (l) => Math.max(0, LEVELS.indexOf(l));

const router = express.Router();

function avg(values) {
  const v = values.filter((x) => typeof x === 'number');
  return v.length ? Math.round((v.reduce((a, b) => a + b, 0) / v.length) * 100) / 100 : null;
}

function buildSummary(session, readings, events) {
  const end = session.endedAt ? new Date(session.endedAt) : new Date();
  const levelCounts = Object.fromEntries(LEVELS.map((l) => [l, 0]));
  let peak = 'normal';
  for (const r of readings) {
    if (r.fatigueLevel) {
      levelCounts[r.fatigueLevel] += 1;
      if (levelRank(r.fatigueLevel) > levelRank(peak)) peak = r.fatigueLevel;
    }
  }
  const severityCounts = { Warning: 0, High: 0, Critical: 0 };
  for (const e of events) severityCounts[e.severity] += 1;
  return {
    sessionId: session._id,
    pilotId: session.pilotId,
    status: session.status,
    startedAt: session.startedAt,
    endedAt: session.endedAt,
    durationSeconds: Math.max(0, Math.round((end - new Date(session.startedAt)) / 1000)),
    readingCount: readings.length,
    eventCount: events.length,
    peakLevel: peak,
    averages: {
      heartRateBpm: avg(readings.map((r) => r.heartRateBpm)),
      blinkRatePerMinute: avg(readings.map((r) => r.blinkRatePerMinute)),
      ear: avg(readings.map((r) => r.ear)),
      fatigueScore: avg(readings.map((r) => r.fatigueScore)),
    },
    levelCounts,
    severityCounts,
  };
}

router.post('/', async (req, res, next) => {
  try {
    const session = await MonitoringSession.create({
      pilotId: req.body.pilotId || 'pilot-001',
      notes: req.body.notes || '',
      status: 'active',
    });
    res.status(201).json({ success: true, message: 'Session created', data: session });
  } catch (error) { next(error); }
});

router.get('/', async (_req, res, next) => {
  try {
    const sessions = await MonitoringSession.find().sort({ startedAt: -1 }).limit(100);
    res.json({ success: true, data: sessions });
  } catch (error) { next(error); }
});

router.get('/:id', async (req, res, next) => {
  try {
    if (!mongoose.isValidObjectId(req.params.id)) {
      return res.status(400).json({ success: false, message: 'Invalid session ID.' });
    }
    const session = await MonitoringSession.findById(req.params.id);
    if (!session) return res.status(404).json({ success: false, message: 'Session not found.' });
    const [readings, events] = await Promise.all([
      SensorReading.find({ sessionId: session._id }).sort({ recordedAt: -1 }).limit(200),
      FatigueEvent.find({ sessionId: session._id }).sort({ occurredAt: -1 }).limit(100),
    ]);
    res.json({ success: true, data: { session, readings, events } });
  } catch (error) { next(error); }
});

router.get('/:id/summary', async (req, res, next) => {
  try {
    if (!mongoose.isValidObjectId(req.params.id)) {
      return res.status(400).json({ success: false, message: 'Invalid session ID.' });
    }
    const session = await MonitoringSession.findById(req.params.id);
    if (!session) return res.status(404).json({ success: false, message: 'Session not found.' });
    const [readings, events] = await Promise.all([
      SensorReading.find({ sessionId: session._id }).sort({ recordedAt: 1 }).limit(5000),
      FatigueEvent.find({ sessionId: session._id }).sort({ occurredAt: 1 }).limit(1000),
    ]);
    res.json({ success: true, data: buildSummary(session, readings, events) });
  } catch (error) { next(error); }
});

router.patch('/:id', async (req, res, next) => {
  try {
    const allowed = {};
    if (req.body.status !== undefined) {
      if (!['active', 'paused', 'ended'].includes(req.body.status)) {
        return res.status(400).json({ success: false, message: 'status must be active, paused, or ended.' });
      }
      allowed.status = req.body.status;
      if (req.body.status === 'ended') allowed.endedAt = new Date();
      if (req.body.status !== 'ended') allowed.endedAt = null;
    }
    if (req.body.autopilotStatus !== undefined) {
      if (!['unknown', 'on', 'off'].includes(req.body.autopilotStatus)) {
        return res.status(400).json({ success: false, message: 'autopilotStatus must be unknown, on, or off.' });
      }
      allowed.autopilotStatus = req.body.autopilotStatus;
    }
    if (req.body.notes !== undefined) allowed.notes = String(req.body.notes);
    if (!Object.keys(allowed).length) {
      return res.status(400).json({ success: false, message: 'No valid fields supplied.' });
    }
    const session = await MonitoringSession.findByIdAndUpdate(req.params.id, allowed, { new: true, runValidators: true });
    if (!session) return res.status(404).json({ success: false, message: 'Session not found.' });
    res.json({ success: true, message: 'Session updated', data: session });
  } catch (error) { next(error); }
});

module.exports = router;
