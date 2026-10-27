// Password protection for the dashboard and for every route that reads data.
//
// Uses HTTP Basic auth (the browser shows its own login box). The username is
// ignored; the password must equal DASHBOARD_PASSWORD. When DASHBOARD_PASSWORD
// is not set (local development) everything stays open.
const crypto = require('crypto');

const sha256 = (s) => crypto.createHash('sha256').update(String(s)).digest();

function passwordFrom(header) {
  if (!header || !header.startsWith('Basic ')) return null;
  const decoded = Buffer.from(header.slice(6), 'base64').toString('utf8');
  const colon = decoded.indexOf(':');
  return colon === -1 ? null : decoded.slice(colon + 1);
}

function requirePassword(req, res, next) {
  const expected = process.env.DASHBOARD_PASSWORD;
  if (!expected) return next();

  const given = passwordFrom(req.headers.authorization);
  // Compare hashes so the check takes the same time whatever was typed.
  if (given !== null && crypto.timingSafeEqual(sha256(given), sha256(expected))) {
    return next();
  }
  res.set('WWW-Authenticate', 'Basic realm="Fatigue dashboard", charset="UTF-8"');
  res.status(401).json({ success: false, message: 'Password required.' });
}

// Protects GET requests only, so the app can keep sending data without a password.
function requirePasswordForReads(req, res, next) {
  if (req.method === 'GET' || req.method === 'HEAD') return requirePassword(req, res, next);
  next();
}

module.exports = { requirePassword, requirePasswordForReads };
