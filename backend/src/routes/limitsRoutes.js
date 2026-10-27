// Driving limits for the app (public: summary figures only, no personal data).
// The app warns the driver before the recommended break and before
// high-risk periods learned from past drives.
const express = require('express');
const analytics = require('../services/analytics');

const router = express.Router();
const TIMEZONE = process.env.DASHBOARD_TIMEZONE || 'Africa/Johannesburg';
const CACHE_MS = 5 * 60 * 1000; // recompute at most every 5 minutes

let cache = null;

router.get('/', async (_req, res, next) => {
  try {
    if (!cache || Date.now() - cache.at > CACHE_MS) {
      const overview = await analytics.loadOverview({
        days: 90,
        // Set LIMITS_INCLUDE_DEMO=true to base the limits on demo data too
        includeDemo: process.env.LIMITS_INCLUDE_DEMO === 'true',
        tz: TIMEZONE,
      });
      cache = { at: Date.now(), data: analytics.limitsFromOverview(overview) };
    }
    res.json({ success: true, data: cache.data });
  } catch (error) { next(error); }
});

module.exports = router;
