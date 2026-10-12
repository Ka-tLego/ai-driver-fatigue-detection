const mongoose = require('mongoose');

const fatigueEventSchema = new mongoose.Schema({
  sessionId: { type: mongoose.Schema.Types.ObjectId, ref: 'MonitoringSession', required: true, index: true },
  severity: { type: String, enum: ['Warning', 'High', 'Critical'], required: true },
  message: { type: String, required: true, trim: true },
  fatigueLevel: { type: String, enum: ['normal', 'warning', 'high', 'critical'] },
  occurredAt: { type: Date, default: Date.now },
}, { timestamps: true });

module.exports = mongoose.model('FatigueEvent', fatigueEventSchema);
