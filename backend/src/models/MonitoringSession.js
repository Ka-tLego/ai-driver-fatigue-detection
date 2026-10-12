const mongoose = require('mongoose');

const monitoringSessionSchema = new mongoose.Schema({
  pilotId: { type: String, required: true, trim: true, default: 'pilot-001' },
  status: { type: String, enum: ['active', 'paused', 'ended'], default: 'active' },
  autopilotStatus: { type: String, enum: ['unknown', 'on', 'off'], default: 'unknown' },
  notes: { type: String, default: '' },
  startedAt: { type: Date, default: Date.now },
  endedAt: { type: Date, default: null },
}, { timestamps: true });

module.exports = mongoose.model('MonitoringSession', monitoringSessionSchema);
