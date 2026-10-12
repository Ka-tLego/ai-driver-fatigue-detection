const express = require('express');
const mongoose = require('mongoose');
const MonitoringSession = require('../models/MonitoringSession');
const FatigueEvent = require('../models/FatigueEvent');

const router = express.Router();

router.post('/', async (req, res, next) => {
  try {
    const { sessionId, severity, message, fatigueLevel } = req.body;
    if (!mongoose.isValidObjectId(sessionId)) {
      return res.status(400).json({ success: false, message: 'A valid sessionId is required.' });
    }
    if (!['Warning', 'High', 'Critical'].includes(severity)) {
      return res.status(400).json({ success: false, message: 'severity must be Warning, High, or Critical.' });
    }
    if (!message || !String(message).trim()) {
      return res.status(400).json({ success: false, message: 'message is required.' });
    }
    const session = await MonitoringSession.findById(sessionId);
    if (!session) return res.status(404).json({ success: false, message: 'Session not found.' });
    const event = await FatigueEvent.create({ sessionId, severity, message, fatigueLevel });
    res.status(201).json({ success: true, message: 'Fatigue event saved', data: event });
  } catch (error) { next(error); }
});

router.get('/', async (req, res, next) => {
  try {
    const filter = {};
    if (req.query.sessionId) {
      if (!mongoose.isValidObjectId(req.query.sessionId)) {
        return res.status(400).json({ success: false, message: 'Invalid sessionId.' });
      }
      filter.sessionId = req.query.sessionId;
    }
    const events = await FatigueEvent.find(filter).sort({ occurredAt: -1 }).limit(200);
    res.json({ success: true, data: events });
  } catch (error) { next(error); }
});

module.exports = router;
