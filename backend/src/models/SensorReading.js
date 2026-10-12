const mongoose = require('mongoose');

const sensorReadingSchema = new mongoose.Schema({
  sessionId: { type: mongoose.Schema.Types.ObjectId, ref: 'MonitoringSession', required: true, index: true },
  heartRateBpm: { type: Number, min: 0 },
  blinkRatePerMinute: { type: Number, min: 0 },
  ear: { type: Number, min: 0, max: 1 },
  fatigueLevel: { type: String, enum: ['normal', 'warning', 'high', 'critical'] },
  fatigueScore: { type: Number, min: 0, max: 100 },
  source: { type: String, default: 'flutter_app' },
  recordedAt: { type: Date, default: Date.now },
}, { timestamps: true });

sensorReadingSchema.index({ sessionId: 1, recordedAt: -1 });

module.exports = mongoose.model('SensorReading', sensorReadingSchema);
