const express = require('express');
const mongoose = require('mongoose');
const MonitoringSession = require('../models/MonitoringSession');
const SensorReading = require('../models/SensorReading');

const router = express.Router();
const LEVELS = ['normal', 'warning', 'high', 'critical'];

function optionalNumber(value, name, { min, max } = {}) {
  if (value === undefined || value === null || value === '') return undefined;
  const n = Number(value);
  if (!Number.isFinite(n)) throw Object.assign(new Error(`${name} must be a number.`), { status: 400 });
  if (min !== undefined && n < min) throw Object.assign(new Error(`${name} must be >= ${min}.`), { status: 400 });
  if (max !== undefined && n > max) throw Object.assign(new Error(`${name} must be <= ${max}.`), { status: 400 });
  return n;
}

// Store one monitoring reading sent by the Flutter app.
router.post('/:id/readings', async (req, res, next) => {
  try {
    if (!mongoose.isValidObjectId(req.params.id)) {
      return res.status(400).json({ success: false, message: 'Invalid session ID.' });
    }
    const session = await MonitoringSession.findById(req.params.id);
    if (!session) return res.status(404).json({ success: false, message: 'Session not found.' });
    if (session.status === 'ended') {
      return res.status(409).json({ success: false, message: 'Session has ended; no more readings accepted.' });
    }

    let heartRateBpm, blinkRatePerMinute, ear, fatigueScore;
    try {
      heartRateBpm = optionalNumber(req.body.heartRateBpm, 'heartRateBpm', { min: 0, max: 300 });
      blinkRatePerMinute = optionalNumber(req.body.blinkRatePerMinute, 'blinkRatePerMinute', { min: 0, max: 200 });
      ear = optionalNumber(req.body.ear, 'ear', { min: 0, max: 1 });
      fatigueScore = optionalNumber(req.body.fatigueScore, 'fatigueScore', { min: 0, max: 100 });
    } catch (e) {
      return res.status(e.status || 400).json({ success: false, message: e.message });
    }
    if (req.body.fatigueLevel !== undefined && !LEVELS.includes(req.body.fatigueLevel)) {
      return res.status(400).json({ success: false, message: `fatigueLevel must be one of: ${LEVELS.join(', ')}.` });
    }
    let recordedAt = new Date();
    if (req.body.recordedAt) {
      recordedAt = new Date(req.body.recordedAt);
      if (Number.isNaN(recordedAt.getTime())) {
        return res.status(400).json({ success: false, message: 'recordedAt must be a valid date.' });
      }
    }

    const reading = await SensorReading.create({
      sessionId: session._id,
      heartRateBpm,
      blinkRatePerMinute,
      ear,
      fatigueLevel: req.body.fatigueLevel,
      fatigueScore,
      source: req.body.source || 'flutter_app',
      recordedAt,
    });
    res.status(201).json({ success: true, message: 'Sensor reading saved', data: reading });
  } catch (error) { next(error); }
});

// Retrieve stored readings (newest first).
router.get('/:id/readings', async (req, res, next) => {
  try {
    if (!mongoose.isValidObjectId(req.params.id)) {
      return res.status(400).json({ success: false, message: 'Invalid session ID.' });
    }
    const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 100, 1), 1000);
    const readings = await SensorReading.find({ sessionId: req.params.id }).sort({ recordedAt: -1 }).limit(limit);
    res.json({ success: true, data: readings });
  } catch (error) { next(error); }
});

module.exports = router;
