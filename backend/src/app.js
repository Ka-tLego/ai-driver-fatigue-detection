const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');

const sessionRoutes = require('./routes/sessionRoutes');
const readingRoutes = require('./routes/readingRoutes');
const eventRoutes = require('./routes/eventRoutes');

const app = express();
// Hosted behind a proxy (e.g. Render): use the client's real IP for rate limiting.
app.set('trust proxy', 1);
const configuredOrigin = process.env.CORS_ORIGIN;

app.use(helmet());
app.use(cors({
  origin: configuredOrigin
    ? configuredOrigin.split(',').map((value) => value.trim())
    : true,
}));
app.use(express.json({ limit: '1mb' }));
app.use(rateLimit({ windowMs: 60 * 1000, limit: 300 }));

app.get('/api/health', (_req, res) => {
  res.json({
    success: true,
    message: 'Fatigue backend is healthy',
    timestamp: new Date().toISOString(),
  });
});

app.use('/api/sessions', sessionRoutes);
app.use('/api/sessions', readingRoutes);
app.use('/api/events', eventRoutes);

app.use((req, res) => {
  res.status(404).json({ success: false, message: `Route not found: ${req.method} ${req.originalUrl}` });
});

app.use((err, _req, res, _next) => {
  console.error(err);
  if (err.name === 'ValidationError') {
    return res.status(400).json({ success: false, message: err.message });
  }
  if (err.name === 'CastError') {
    return res.status(400).json({ success: false, message: 'Invalid identifier.' });
  }
  res.status(500).json({ success: false, message: 'Internal server error.' });
});

module.exports = app;
