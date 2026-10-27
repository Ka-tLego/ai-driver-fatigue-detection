// The menu simulations, fed through the real fatigue logic (compressed memory).

import 'package:flutter_test/flutter_test.dart';

import 'package:pilot_fatigue_app/ai/fatigue_estimator.dart';
import 'package:pilot_fatigue_app/sim/fatigue_simulator.dart';

/// Runs [scenario] at 10 frames/s and records the highest level per phase,
/// in the order the phases happened.
List<MapEntry<String, FatigueLevel>> run(SimScenario scenario, Duration length) {
  final sim = FatigueSimulator(scenario);
  final est = FatigueEstimator(tuning: FatigueTuning.simulation);
  final phases = <MapEntry<String, FatigueLevel>>[];
  var t = DateTime(2026, 10, 28, 9);
  final end = t.add(length);
  while (t.isBefore(end)) {
    final frame = sim.next(t, est.level);
    est.update(frame.observation);
    if (phases.isEmpty || phases.last.key != frame.phase) {
      phases.add(MapEntry(frame.phase, est.level));
    } else if (est.level.index > phases.last.value.index) {
      phases.last = MapEntry(frame.phase, est.level);
    }
    t = t.add(const Duration(milliseconds: 100));
  }
  return phases;
}

/// Level at the very end of each phase, in order.
List<MapEntry<String, FatigueLevel>> endLevels(SimScenario scenario, Duration length) {
  final sim = FatigueSimulator(scenario);
  final est = FatigueEstimator(tuning: FatigueTuning.simulation);
  final out = <MapEntry<String, FatigueLevel>>[];
  var t = DateTime(2026, 10, 28, 9);
  final end = t.add(length);
  String? phase;
  var last = FatigueLevel.normal;
  while (t.isBefore(end)) {
    final frame = sim.next(t, est.level);
    if (phase != null && frame.phase != phase) out.add(MapEntry(phase, last));
    phase = frame.phase;
    est.update(frame.observation);
    last = est.level;
    t = t.add(const Duration(milliseconds: 100));
  }
  return out;
}

void main() {
  test('Normal ↔ Warning: warning during warning data, back to normal after', () {
    final p = run(SimScenario.warning, const Duration(minutes: 3));
    expect(p[0].key, 'Normal data');
    expect(p[0].value, FatigueLevel.normal);
    expect(p[1].key, 'Warning-level data');
    expect(p[1].value, FatigueLevel.warning);
    expect(p[2].key, 'Recovering');
    expect(endLevels(SimScenario.warning, const Duration(minutes: 3))[2].value, FatigueLevel.normal);
    expect(p.length, greaterThan(3), reason: 'loops');
  });

  test('Normal ↔ High: high during high data, back to normal after', () {
    final p = run(SimScenario.high, const Duration(minutes: 3));
    expect(p[0].value, FatigueLevel.normal);
    expect(p[1].key, 'High-level data');
    expect(p[1].value, FatigueLevel.high);
    expect(endLevels(SimScenario.high, const Duration(minutes: 3))[2].value, FatigueLevel.normal);
  });

  test('Normal ↔ Critical: critical during critical data, back to normal after', () {
    final p = run(SimScenario.critical, const Duration(minutes: 4));
    expect(p[1].key, 'Critical-level data');
    expect(p[1].value, FatigueLevel.critical);
    expect(endLevels(SimScenario.critical, const Duration(minutes: 4))[2].value, FatigueLevel.normal);
  });

  test('Full cycle steps through every level and back', () {
    final p = run(SimScenario.fullCycle, const Duration(minutes: 5));
    expect(p.take(5).map((e) => e.key), [
      'Normal data', 'Warning-level data', 'High-level data', 'Critical-level data', 'Recovering',
    ]);
    expect(p[1].value, FatigueLevel.warning);
    expect(p[2].value, FatigueLevel.high);
    expect(p[3].value, FatigueLevel.critical);
    expect(endLevels(SimScenario.fullCycle, const Duration(minutes: 5))[4].value, FatigueLevel.normal);
  });

  test('the level rises gradually during the fatigued phase, not instantly', () {
    final sim = FatigueSimulator(SimScenario.warning);
    final est = FatigueEstimator(tuning: FatigueTuning.simulation);
    var t = DateTime(2026, 10, 28, 9);
    FatigueLevel at5s = FatigueLevel.normal;
    for (var i = 0; i < 350; i++) { // 30 s normal + 5 s warning data
      est.update(sim.next(t, est.level).observation);
      t = t.add(const Duration(milliseconds: 100));
    }
    at5s = est.level;
    expect(at5s, FatigueLevel.normal, reason: 'not straight away');
  });
}
