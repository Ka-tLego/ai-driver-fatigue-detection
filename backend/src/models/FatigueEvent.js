const mongoose = require('mongoose');

const fatigueEventSchema = new mongoose.Schema({
  sessionId: { type: mongoose.Schema.Types.ObjectId, ref: 'MonitoringSession', required: true, index: true },
  severity: { type: String, enum: ['Warning', 'High', 'Critical'], required: true },
  message: { type: String, required: true, trim: true },
  fatigueLevel: { type: String, enum: ['normal', 'warning', 'high', 'critical'] },
  // Pilot's state at the moment of the event (all optional)
  heartRateBpm: { type: Number, min: 0 },
  blinkRatePerMinute: { type: Number, min: 0 },
  ear: { type: Number, min: 0, max: 1 },
  closureSeconds: { type: Number, min: 0 },
  occurredAt: { type: Date, default: Date.now, index: true },
}, { timestamps: true });

module.exports = mongoose.model('FatigueEvent', fatigueEventSchema);
