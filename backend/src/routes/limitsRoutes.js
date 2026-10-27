// Driving limits for the app (public: summary figures only, no personal data).
// The app warns the driver before the recommended break and before
// high-risk periods learned from past drives.
//
//   GET /api/limits                   real drives only (or demo too if LIMITS_INCLUDE_DEMO=true)
//   GET /api/limits?includeDemo=true  real + demo drives (used by the app's simulations)
const express = require('express');
const analytics = require('../services/analytics');

const router = express.Router();
const TIMEZONE = process.env.DASHBOARD_TIMEZONE || 'Africa/Johannesburg';
const CACHE_MS = 5 * 60 * 1000; // recompute at most every 5 minutes

const cache = new Map(); // includeDemo -> { at, data }

router.get('/', async (req, res, next) => {
  try {
    const includeDemo = req.query.includeDemo === 'true' || process.env.LIMITS_INCLUDE_DEMO === 'true';
    let entry = cache.get(includeDemo);
    if (!entry || Date.now() - entry.at > CACHE_MS) {
      const overview = await analytics.loadOverview({ days: 90, includeDemo, tz: TIMEZONE });
      entry = { at: Date.now(), data: { ...analytics.limitsFromOverview(overview), includesDemo: includeDemo } };
      cache.set(includeDemo, entry);
    }
    res.json({ success: true, data: entry.data });
  } catch (error) { next(error); }
});

module.exports = router;
