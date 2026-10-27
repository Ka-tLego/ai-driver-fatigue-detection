// Simulated drives for the fatigue score (10 frames per second).

import 'package:flutter_test/flutter_test.dart';

import 'package:pilot_fatigue_app/ai/fatigue_estimator.dart';

class Sim {
  final est = FatigueEstimator();
  DateTime t = DateTime(2026, 10, 28, 8);
  FatigueLevel maxLevel = FatigueLevel.normal;
  double maxScore = 0;

  static const step = Duration(milliseconds: 100);

  void frames(
    Duration d, {
    bool closed = false,
    double mouth = 0.02,
    double pitch = 0,
    int? hr,
  }) {
    for (var i = 0; i < d.inMilliseconds ~/ 100; i++) {
      t = t.add(step);
      est.update(FrameObservation(
        time: t,
        eyesClosed: closed,
        mouthRatio: mouth,
        headPitch: pitch,
        heartRateBpm: hr,
      ));
      if (est.level.index > maxLevel.index) maxLevel = est.level;
      if (est.score > maxScore) maxScore = est.score;
    }
  }

  /// Alert driving: a 200 ms blink every 4 s (15 blinks / min).
  void alert(Duration d, {int? hr}) {
    for (var s = 0; s < d.inSeconds; s += 4) {
      frames(const Duration(milliseconds: 200), closed: true, hr: hr);
      frames(const Duration(milliseconds: 3800), hr: hr);
    }
  }

  /// Drowsy driving: a 600 ms slow blink every 6 s.
  void drowsy(Duration d) {
    for (var s = 0; s < d.inSeconds; s += 6) {
      frames(const Duration(milliseconds: 600), closed: true);
      frames(const Duration(milliseconds: 5400));
    }
  }

  /// A yawn: mouth wide open for 4 s with the eyes squeezed shut.
  void yawn() {
    frames(const Duration(seconds: 4), closed: true, mouth: 0.6);
    frames(const Duration(milliseconds: 500), closed: true, mouth: 0.05);
  }

  void reset() {
    maxLevel = FatigueLevel.normal;
    maxScore = 0;
  }
}

void main() {
  test('a single yawn does not raise fatigue', () {
    final sim = Sim()..alert(const Duration(minutes: 2));
    sim.reset();
    sim.yawn();
    sim.alert(const Duration(minutes: 2));

    expect(sim.maxLevel, FatigueLevel.normal);
    expect(sim.est.recentYawns, 1);
    expect(sim.maxScore, lessThan(kWarningScore));
    expect(sim.est.recentMicrosleeps, 0, reason: 'eyes shut during a yawn are not a microsleep');
  });

  test('talking is not counted as yawning', () {
    final sim = Sim()..alert(const Duration(minutes: 1));
    for (var i = 0; i < 60; i++) {
      sim.frames(const Duration(milliseconds: 500), mouth: 0.35);
      sim.frames(const Duration(milliseconds: 500), mouth: 0.1);
    }
    expect(sim.est.recentYawns, 0);
    expect(sim.maxLevel, FatigueLevel.normal);
  });

  test('a real microsleep alarms immediately, then eases off', () {
    final sim = Sim()..alert(const Duration(minutes: 2));
    sim.frames(const Duration(milliseconds: 1600), closed: true);
    expect(sim.est.level, FatigueLevel.high, reason: 'eyes closed 1.6 s');
    sim.frames(const Duration(milliseconds: 1600), closed: true);
    expect(sim.est.level, FatigueLevel.critical, reason: 'eyes closed 3.2 s');
    expect(sim.est.reason, contains('eyes closed'));

    sim.alert(const Duration(seconds: 8));
    expect(sim.est.level.index, lessThan(FatigueLevel.high.index));
    expect(sim.est.recentMicrosleeps, 1);
  });

  test('fatigue builds up gradually from slow blinks and yawns', () {
    final sim = Sim()..alert(const Duration(minutes: 2));
    sim.reset();

    sim.drowsy(const Duration(seconds: 18));
    expect(sim.est.level, FatigueLevel.normal, reason: 'not after a few slow blinks');

    for (var i = 0; i < 4; i++) {
      sim.drowsy(const Duration(minutes: 2));
      sim.yawn();
    }
    expect(sim.est.level.index, greaterThanOrEqualTo(FatigueLevel.warning.index));
    expect(sim.est.score, greaterThan(kWarningScore));
    expect(sim.est.reason, isNotEmpty);
  });

  test('moderate drowsiness with microsleeps and nods is high, not critical', () {
    final sim = Sim();
    for (var i = 0; i < 5; i++) {
      sim.drowsy(const Duration(seconds: 50));
      sim.frames(const Duration(milliseconds: 1200), closed: true); // microsleep
      sim.frames(const Duration(seconds: 2), pitch: -30); // nod
      sim.yawn();
    }
    sim.drowsy(const Duration(seconds: 30));
    expect(sim.est.level, FatigueLevel.high);
  });

  test('nodding off (eyes shut a third of the time) reaches critical', () {
    final sim = Sim();
    for (var i = 0; i < 4; i++) {
      for (var k = 0; k < 15; k++) {
        sim.frames(const Duration(milliseconds: 1200), closed: true);
        sim.frames(const Duration(milliseconds: 2800));
      }
      sim.frames(const Duration(seconds: 2), pitch: -30); // nod
      sim.yawn();
    }
    expect(sim.est.level, FatigueLevel.critical);
    expect(sim.est.perclos, greaterThan(0.25));
  });

  test('recovers to normal after a long alert stretch', () {
    final sim = Sim();
    for (var i = 0; i < 4; i++) {
      sim.drowsy(const Duration(minutes: 2));
      sim.yawn();
    }
    expect(sim.est.level.index, greaterThanOrEqualTo(FatigueLevel.warning.index));

    sim.alert(const Duration(minutes: 1));
    expect(sim.est.level.index, greaterThanOrEqualTo(FatigueLevel.warning.index),
        reason: 'fatigue wears off slowly, not instantly');

    sim.alert(const Duration(minutes: 12));
    expect(sim.est.level, FatigueLevel.normal);
  });

  test('a heart-rate drop below the pilot\'s baseline adds to the score', () {
    final sim = Sim()..alert(const Duration(minutes: 5), hr: 75);
    final before = sim.est.score;
    sim.alert(const Duration(minutes: 1), hr: 63);
    expect(sim.est.score, greaterThan(before + 5));
    expect(sim.est.reason, 'heart rate dropping');
  });
}
