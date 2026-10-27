// Read-only data for the dashboard (password-protected in app.js).
const express = require('express');
const mongoose = require('mongoose');
const analytics = require('../services/analytics');

const router = express.Router();
const TIMEZONE = process.env.DASHBOARD_TIMEZONE || 'Africa/Johannesburg';

// ?days=7|30|90 (omit for all time) &includeDemo=true
function filters(query) {
  const days = Number(query.days);
  return {
    days: Number.isFinite(days) && days > 0 ? Math.min(days, 3650) : null,
    includeDemo: query.includeDemo === 'true',
  };
}

router.get('/overview', async (req, res, next) => {
  try {
    const data = await analytics.loadOverview({ ...filters(req.query), tz: TIMEZONE });
    res.json({ success: true, data });
  } catch (error) { next(error); }
});

router.get('/sessions', async (req, res, next) => {
  try {
    const data = await analytics.loadSessionList(filters(req.query));
    res.json({ success: true, data });
  } catch (error) { next(error); }
});

router.get('/sessions/:id/timeline', async (req, res, next) => {
  try {
    if (!mongoose.isValidObjectId(req.params.id)) {
      return res.status(400).json({ success: false, message: 'Invalid session ID.' });
    }
    const data = await analytics.loadTimeline(req.params.id);
    if (!data) return res.status(404).json({ success: false, message: 'Session not found.' });
    res.json({ success: true, data });
  } catch (error) { next(error); }
});

module.exports = router;
