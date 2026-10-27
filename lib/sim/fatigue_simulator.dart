// Fatigue simulations
//
// Produces made-up camera measurements (eyes, mouth, head, heart rate) that
// are fed into the normal fatigue logic, so the score, levels, alarms and
// messages react exactly as they would to a real driver.
//
// Each scenario loops: 30 s of normal data, 30 s of data typical of the
// level, then normal data until the level is back to normal.

import '../ai/fatigue_estimator.dart';

enum SimScenario { warning, high, critical, fullCycle }

extension SimScenarioName on SimScenario {
  String get label => switch (this) {
        SimScenario.warning => 'Normal ↔ Warning',
        SimScenario.high => 'Normal ↔ High',
        SimScenario.critical => 'Normal ↔ Critical',
        SimScenario.fullCycle => 'Full cycle',
      };
}

/// One simulated camera frame.
class SimFrame {
  final FrameObservation observation;
  final double ear; // eye aspect ratio to display
  final String phase; // e.g. "Warning-level data"
  final int? secondsLeft; // null while waiting for recovery

  const SimFrame(this.observation, this.ear, this.phase, this.secondsLeft);
}

typedef _Pattern = ({bool closed, double mouth, double pitch, int hr}) Function(
    double t);

class _Phase {
  final String name;
  final double seconds; // minimum length
  final _Pattern pattern;
  final bool untilNormal; // keep going until the level is back to normal

  const _Phase(this.name, this.seconds, this.pattern, {this.untilNormal = false});
}

const double kSimPhaseSeconds = 30;
const double kSimMaxRecoverySeconds = 120;

bool _between(double t, double from, double to) => t >= from && t < to;

// ======================================
// DRIVER BEHAVIOUR PER LEVEL (t = seconds into the phase)
// ======================================

/// Alert: a quick 0.2 s blink every 4 s.
({bool closed, double mouth, double pitch, int hr}) _normal(double t) =>
    (closed: t % 4 < 0.2, mouth: 0.02, pitch: 0, hr: 72);

/// Warning: slow 0.5 s blinks every 2.2 s and a yawn.
({bool closed, double mouth, double pitch, int hr}) _warning(double t) {
  final yawn = _between(t, 10, 14);
  return (closed: yawn || t % 2.2 < 0.5, mouth: yawn ? 0.6 : 0.03, pitch: 0, hr: 70);
}

/// High: 1.2 s eye closures (microsleeps) every 3.5 s, two yawns, a head nod.
({bool closed, double mouth, double pitch, int hr}) _high(double t) {
  final yawn = _between(t, 4, 8) || _between(t, 19, 23);
  final nod = _between(t, 10, 12);
  return (
    closed: yawn || t % 3.5 < 1.2,
    mouth: yawn ? 0.6 : 0.03,
    pitch: nod ? -30 : 0,
    hr: 66,
  );
}

/// Critical: eyes shut half the time (1.3 s closures every 2.5 s), nods,
/// yawns, and a 3.5 s closure.
({bool closed, double mouth, double pitch, int hr}) _critical(double t) {
  final yawn = _between(t, 3, 7) || _between(t, 11, 15) || _between(t, 24, 28);
  final nod = _between(t, 8, 10) || _between(t, 15, 17);
  final longClosure = _between(t, 20, 23.5);
  return (
    closed: yawn || longClosure || t % 2.5 < 1.3,
    mouth: yawn ? 0.6 : 0.03,
    pitch: nod ? -30 : 0,
    hr: 62,
  );
}

const _normalPhase = _Phase('Normal data', kSimPhaseSeconds, _normal);
const _recovery =
    _Phase('Recovering', kSimPhaseSeconds, _normal, untilNormal: true);

class FatigueSimulator {
  final SimScenario scenario;
  final List<_Phase> _phases;
  int _index = 0;
  DateTime? _phaseStart;

  FatigueSimulator(this.scenario) : _phases = _phasesFor(scenario);

  static List<_Phase> _phasesFor(SimScenario s) {
    const warning = _Phase('Warning-level data', kSimPhaseSeconds, _warning);
    const high = _Phase('High-level data', kSimPhaseSeconds, _high);
    const critical = _Phase('Critical-level data', kSimPhaseSeconds, _critical);
    return switch (s) {
      SimScenario.warning => [_normalPhase, warning, _recovery],
      SimScenario.high => [_normalPhase, high, _recovery],
      SimScenario.critical => [_normalPhase, critical, _recovery],
      SimScenario.fullCycle => [_normalPhase, warning, high, critical, _recovery],
    };
  }

  /// The next simulated frame. [level] is the current fatigue level, used to
  /// end the recovery phase once the driver is back to normal.
  SimFrame next(DateTime now, FatigueLevel level) {
    _phaseStart ??= now;
    var phase = _phases[_index];
    var t = now.difference(_phaseStart!).inMilliseconds / 1000.0;

    final done = phase.untilNormal
        ? (t >= phase.seconds && level == FatigueLevel.normal) ||
            t >= kSimMaxRecoverySeconds
        : t >= phase.seconds;
    if (done) {
      _index = (_index + 1) % _phases.length; // loop
      _phaseStart = now;
      phase = _phases[_index];
      t = 0;
    }

    final p = phase.pattern(t);
    final secondsLeft = phase.untilNormal && t >= phase.seconds
        ? null
        : (phase.seconds - t).ceil();
    return SimFrame(
      FrameObservation(
        time: now,
        eyesClosed: p.closed,
        mouthRatio: p.mouth,
        headPitch: p.pitch,
        heartRateBpm: p.hr,
      ),
      p.closed ? 0.12 : 0.30,
      phase.name,
      secondsLeft,
    );
  }
}
