// Fatigue score
//
// Turns per-frame observations (eyes closed?, mouth opening, head pitch,
// heart rate) into a fatigue score (0-100) that builds up and wears off
// over time, instead of reacting to a single frame.
//
// Kept free of camera / ML Kit code so it can be unit-tested with
// simulated drives.

import 'dart:collection';
import 'dart:math';

enum FatigueLevel { normal, warning, high, critical }

// ======================================
// TUNING CONSTANTS (adjust while testing)
// ======================================

// ----- Mouth / yawns (mouth aspect ratio = opening height / mouth width) -----
const double kMouthOpenRatio = 0.30; // mouth wide open (yawn or big talk)
const double kYawnPeakRatio = 0.45; // a yawn opens at least this wide
const int kYawnMinMs = 1500; // and stays open at least this long
const int kYawnGuardMs = 1000; // ignore eye closure this long after a yawn

// ----- Eyes -----
const int kMinBlinkMs = 60; // shorter = noise
const int kSlowBlinkMs = 400; // 400 ms - 1 s = slow (drowsy) blink
const int kMicrosleepMs = 1000; // >= 1 s = microsleep

// ----- Head -----
const double kHeadDownPitch = -20; // degrees
const int kNodMs = 1500; // head down this long = a nod

// ----- Windows -----
const int kPerclosWindowSec = 60;
const int kBlinkWindowSec = 60;
const int kEyeEventWindowSec = 300; // slow blinks, microsleeps, nods
const int kYawnWindowSec = 600;
const int kHrBaselineSec = 300; // first 5 min of heart rate = the pilot's baseline

// ----- Score weights (sum = 100) -----
const double kWeightPerclos = 30;
const double kWeightEyeEvents = 25;
const double kWeightYawns = 15;
const double kWeightNods = 15;
const double kWeightHeartRate = 10;
const double kWeightBlinkRate = 5;

// ----- Score smoothing -----
const double kRiseSeconds = 8; // score rises over ~8 s
const double kFallSeconds = 90; // and falls over ~90 s

// ----- Levels -----
const double kWarningScore = 30;
const double kHighScore = 55;
const double kCriticalScore = 80;
// Levels go up immediately; to go down one level, the score must stay
// below the current level's range this long. One step down at a time.
const Duration kLevelDwell = Duration(seconds: 30);

// ----- Immediate safety overrides -----
const double kHighClosureSec = 1.5; // eyes closed (not yawning) -> at least HIGH
const double kCriticalClosureSec = 3.0; // -> CRITICAL
const double kHighHeadDownSec = 3.0; // head down -> at least HIGH

/// One camera frame's worth of measurements.
class FrameObservation {
  final DateTime time;
  final bool eyesClosed;
  final double? mouthRatio;
  final double? headPitch; // degrees, negative = looking down
  final int? heartRateBpm;

  const FrameObservation({
    required this.time,
    required this.eyesClosed,
    this.mouthRatio,
    this.headPitch,
    this.heartRateBpm,
  });
}

class _Sample {
  final DateTime time;
  final bool closed;
  _Sample(this.time, this.closed);
}

/// Decides the shown level from the target level (score level or a safety
/// alarm, whichever is higher). Going up is immediate. Going down needs the
/// target to stay below the current level for kLevelDwell, then drops one
/// level; each further step down needs another kLevelDwell. So every level
/// is held at least 30 s, however it was reached. Critical -> normal takes
/// at least 3 x kLevelDwell.
class LevelGate {
  FatigueLevel level = FatigueLevel.normal;
  DateTime? _downSince;

  static double threshold(FatigueLevel l) => switch (l) {
        FatigueLevel.critical => kCriticalScore,
        FatigueLevel.high => kHighScore,
        FatigueLevel.warning => kWarningScore,
        FatigueLevel.normal => 0,
      };

  static FatigueLevel levelFor(double score) {
    if (score >= kCriticalScore) return FatigueLevel.critical;
    if (score >= kHighScore) return FatigueLevel.high;
    if (score >= kWarningScore) return FatigueLevel.warning;
    return FatigueLevel.normal;
  }

  FatigueLevel update(FatigueLevel target, DateTime t) {
    if (target.index > level.index) {
      level = target; // up: immediately
      _downSince = null;
    } else if (target.index < level.index) {
      _downSince ??= t; // below the current range: start / keep timing
      if (t.difference(_downSince!) >= kLevelDwell) {
        level = FatigueLevel.values[level.index - 1];
        _downSince = null; // the next step down needs its own 30 s
      }
    } else {
      _downSince = null; // back in the current range: start over
    }
    return level;
  }

  /// Pauses the down timer (e.g. face out of view); keeps the level.
  void interrupt() => _downSince = null;

  void reset() {
    level = FatigueLevel.normal;
    interrupt();
  }
}

class FatigueEstimator {
  // ---------- OUTPUTS ----------
  double score = 0; // 0-100, smoothed
  FatigueLevel level = FatigueLevel.normal; // score level + safety overrides
  String reason = ''; // main cause, e.g. "frequent yawning"
  int blinkRate = 0; // per minute
  double perclos = 0; // fraction of the last minute with eyes closed
  double closureSeconds = 0; // current eye closure (yawns excluded)
  double lastClosureSeconds = 0; // most recent completed closure
  bool yawning = false;
  int recentYawns = 0; // last 10 min
  int recentMicrosleeps = 0; // last 5 min
  int recentNods = 0; // last 5 min

  // ---------- INTERNALS ----------
  final LevelGate _gate = LevelGate();
  double _mouthOpenRatio = kMouthOpenRatio;
  double _yawnPeakRatio = kYawnPeakRatio;

  DateTime? _start;
  DateTime? _last;

  DateTime? _mouthOpenSince;
  double _mouthPeak = 0;
  bool _yawnCounted = false;
  DateTime? _yawnGuardUntil;

  DateTime? _closedSince;
  DateTime? _headDownSince;
  bool _nodCounted = false;

  final Queue<_Sample> _samples = Queue();
  int _closedSamples = 0; // running count of closed samples in _samples
  final List<DateTime> _blinks = [];
  final List<DateTime> _slowBlinks = [];
  final List<DateTime> _microsleeps = [];
  final List<DateTime> _yawns = [];
  final List<DateTime> _nods = [];
  final Queue<MapEntry<DateTime, int>> _heartRates = Queue();
  int _heartRateSum = 0;

  DateTime? _hrStart;
  double _hrSum = 0;
  int _hrCount = 0;
  double? _hrBaseline;

  /// Adjusts the yawn thresholds for a pilot whose mouth is normally a
  /// little open (measured during calibration).
  void setMouthBaseline(double restingRatio) {
    _mouthOpenRatio = max(kMouthOpenRatio, restingRatio + 0.15);
    _yawnPeakRatio = max(kYawnPeakRatio, restingRatio + 0.30);
  }

  /// Clears everything (new pilot / recalibration).
  void reset() {
    score = 0;
    level = FatigueLevel.normal;
    _gate.reset();
    _raisedBy = '';
    reason = '';
    blinkRate = 0;
    perclos = 0;
    closureSeconds = 0;
    lastClosureSeconds = 0;
    yawning = false;
    recentYawns = recentMicrosleeps = recentNods = 0;
    _start = _last = null;
    _samples.clear();
    _closedSamples = 0;
    _blinks.clear();
    _slowBlinks.clear();
    _microsleeps.clear();
    _yawns.clear();
    _nods.clear();
    _heartRates.clear();
    _heartRateSum = 0;
    _hrStart = null;
    _hrSum = 0;
    _hrCount = 0;
    _hrBaseline = null;
    onFaceLost();
  }

  /// Face out of view: drop anything in progress, keep the history.
  void onFaceLost() {
    _mouthOpenSince = null;
    _mouthPeak = 0;
    _yawnCounted = false;
    _yawnGuardUntil = null;
    _closedSince = null;
    _headDownSince = null;
    _nodCounted = false;
    closureSeconds = 0;
    yawning = false;
    _gate.interrupt();
    _last = null; // no score smoothing across the gap
  }

  void update(FrameObservation o) {
    final t = o.time;
    _start ??= t;
    final dt = _last == null
        ? 0.0
        : min(0.5, t.difference(_last!).inMilliseconds / 1000.0);
    _last = t;

    final yawnGuard = _updateMouth(o.mouthRatio, t);
    _updateEyes(o.eyesClosed && !yawnGuard, yawnGuard, t);
    final headDownSec = _updateHead(o.headPitch, t);
    _updateHeartRate(o.heartRateBpm, t);
    _trimWindows(t);

    // ----- Score -----
    final parts = _components(t);
    final target = parts.values.fold<double>(0, (a, b) => a + b);
    final tau = target > score ? kRiseSeconds : kFallSeconds;
    score += (target - score) * (1 - exp(-dt / tau));
    score = score.clamp(0, 100).toDouble();

    // ----- Target level: the score's level, or a safety alarm if higher -----
    var wanted = LevelGate.levelFor(score);
    var wantedReason = _mainReason(parts);
    String? alarm;
    if (closureSeconds >= kCriticalClosureSec) {
      wanted = FatigueLevel.critical;
      alarm = 'eyes closed ${closureSeconds.toStringAsFixed(1)} s';
    } else if (closureSeconds >= kHighClosureSec &&
        wanted.index < FatigueLevel.high.index) {
      wanted = FatigueLevel.high;
      alarm = 'eyes closed ${closureSeconds.toStringAsFixed(1)} s';
    } else if (headDownSec >= kHighHeadDownSec &&
        wanted.index < FatigueLevel.high.index) {
      wanted = FatigueLevel.high;
      alarm = 'head dropped';
    }
    if (alarm != null) wantedReason = alarm;

    // ----- Shown level: up immediately, held >= 30 s before each step down -----
    final before = level;
    level = _gate.update(wanted, t);
    if (level.index > before.index || level == wanted) {
      // Raised now, or the target still explains the level
      reason = wantedReason;
      _raisedBy = wantedReason;
    } else {
      // Held above the target: keep showing what raised it
      reason = _raisedBy.isNotEmpty ? _raisedBy : wantedReason;
    }
    if (level == FatigueLevel.normal) _raisedBy = '';
  }

  String _raisedBy = ''; // cause of the current (held) level

  // ======================================
  // SIGNALS
  // ======================================

  /// Returns true while eye closure should be ignored (yawn in progress).
  bool _updateMouth(double? ratio, DateTime t) {
    final open = ratio != null && ratio >= _mouthOpenRatio;
    if (open) {
      _mouthOpenSince ??= t;
      _mouthPeak = max(_mouthPeak, ratio);
      final ms = t.difference(_mouthOpenSince!).inMilliseconds;
      if (!_yawnCounted && ms >= kYawnMinMs && _mouthPeak >= _yawnPeakRatio) {
        _yawns.add(t);
        _yawnCounted = true;
      }
      // A closure that started just before the mouth opened is part of the yawn
      _closedSince = null;
      closureSeconds = 0;
    } else if (_mouthOpenSince != null) {
      _yawnGuardUntil = t.add(const Duration(milliseconds: kYawnGuardMs));
      _mouthOpenSince = null;
      _mouthPeak = 0;
      _yawnCounted = false;
    }
    yawning = open && _mouthPeak >= _yawnPeakRatio;
    return open || (_yawnGuardUntil != null && t.isBefore(_yawnGuardUntil!));
  }

  void _updateEyes(bool closed, bool excluded, DateTime t) {
    if (!excluded) {
      _samples.add(_Sample(t, closed));
      if (closed) _closedSamples += 1;
    }

    if (closed) {
      _closedSince ??= t;
    } else if (_closedSince != null) {
      final ms = t.difference(_closedSince!).inMilliseconds;
      if (ms >= kMinBlinkMs) {
        lastClosureSeconds = ms / 1000.0;
        if (ms >= kMicrosleepMs) {
          _microsleeps.add(t);
        } else {
          _blinks.add(t);
          if (ms >= kSlowBlinkMs) _slowBlinks.add(t);
        }
      }
      _closedSince = null;
    }
    closureSeconds = _closedSince == null
        ? 0
        : t.difference(_closedSince!).inMilliseconds / 1000.0;
  }

  double _updateHead(double? pitch, DateTime t) {
    if (pitch != null && pitch < kHeadDownPitch) {
      _headDownSince ??= t;
      final ms = t.difference(_headDownSince!).inMilliseconds;
      if (!_nodCounted && ms >= kNodMs) {
        _nods.add(t);
        _nodCounted = true;
      }
      return ms / 1000.0;
    }
    _headDownSince = null;
    _nodCounted = false;
    return 0;
  }

  void _updateHeartRate(int? bpm, DateTime t) {
    if (bpm == null || bpm <= 0) return;
    _heartRates.add(MapEntry(t, bpm));
    _heartRateSum += bpm;
    _hrStart ??= t;
    if (_hrBaseline == null) {
      _hrSum += bpm;
      _hrCount += 1;
      if (t.difference(_hrStart!).inSeconds >= kHrBaselineSec && _hrCount > 0) {
        _hrBaseline = _hrSum / _hrCount;
      }
    }
  }

  void _trimWindows(DateTime t) {
    DateTime ago(int s) => t.subtract(Duration(seconds: s));
    final perclosCutoff = ago(kPerclosWindowSec);
    while (_samples.isNotEmpty && _samples.first.time.isBefore(perclosCutoff)) {
      if (_samples.removeFirst().closed) _closedSamples -= 1;
    }
    _blinks.removeWhere((x) => x.isBefore(ago(kBlinkWindowSec)));
    _slowBlinks.removeWhere((x) => x.isBefore(ago(kEyeEventWindowSec)));
    _microsleeps.removeWhere((x) => x.isBefore(ago(kEyeEventWindowSec)));
    _nods.removeWhere((x) => x.isBefore(ago(kEyeEventWindowSec)));
    _yawns.removeWhere((x) => x.isBefore(ago(kYawnWindowSec)));
    final hrCutoff = ago(60);
    while (_heartRates.isNotEmpty && _heartRates.first.key.isBefore(hrCutoff)) {
      _heartRateSum -= _heartRates.removeFirst().value;
    }
  }

  // ======================================
  // SCORE
  // ======================================

  double _clamp01(double x) => x.clamp(0.0, 1.0).toDouble();

  /// Each signal's contribution in points (out of its weight).
  Map<String, double> _components(DateTime t) {
    final runningSec = t.difference(_start!).inMilliseconds / 1000.0;

    perclos = _samples.isEmpty ? 0 : _closedSamples / _samples.length;
    final blinkWindow = min(kBlinkWindowSec.toDouble(), runningSec);
    blinkRate = blinkWindow >= 15
        ? (_blinks.length * 60 / blinkWindow).round()
        : 0;
    recentYawns = _yawns.length;
    recentMicrosleeps = _microsleeps.length;
    recentNods = _nods.length;

    double hr = 0;
    if (_hrBaseline != null && _heartRates.isNotEmpty) {
      final recent = _heartRateSum / _heartRates.length;
      hr = _clamp01((_hrBaseline! - recent - 3) / 7); // 3 bpm drop -> 0, 10 -> 1
    }

    return {
      'eyes closing often':
          runningSec >= 30 ? kWeightPerclos * _clamp01((perclos - 0.08) / 0.22) : 0,
      'slow blinks / microsleeps': kWeightEyeEvents *
          _clamp01(_slowBlinks.length * 0.08 + _microsleeps.length * 0.35),
      'frequent yawning': kWeightYawns * _clamp01(_yawns.length / 4),
      'head nodding': kWeightNods * _clamp01(_nods.length * 0.5),
      'heart rate dropping': kWeightHeartRate * hr,
      'rapid blinking': runningSec >= 30 && blinkRate > 25
          ? kWeightBlinkRate * _clamp01((blinkRate - 25) / 15)
          : 0,
    };
  }

  String _mainReason(Map<String, double> parts) {
    final top = parts.entries.reduce((a, b) => b.value > a.value ? b : a);
    return top.value >= 3 ? top.key : '';
  }
}
