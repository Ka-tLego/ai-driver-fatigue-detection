// Fatigue alarms and advisory beeps
//
//   WARNING  -> 3 one-second beeps, repeated every minute while in WARNING
//   HIGH     -> 5 one-second beeps, repeated every minute while in HIGH
//   CRITICAL -> continuous alarm
//   Advisory (approaching a break / risky period) -> a single beep
//
// Everything plays at full volume.

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

import '../ai/fatigue_monitor.dart';

const int kWarningBeeps = 3;
const int kHighBeeps = 5;
const Duration kBeepLength = Duration(seconds: 1); // length of beep.wav
const Duration kBeepGap = Duration(milliseconds: 500); // silence between beeps
const Duration kBeepRepeatEvery = Duration(minutes: 1);

const String _beep = 'sounds/beep.wav';
const String _alarm = 'sounds/alert.mp3';

class AlertPlayer {
  final AudioPlayer _alarmPlayer = AudioPlayer(); // fatigue beeps + alarm
  final AudioPlayer _advisoryPlayer = AudioPlayer(); // single advisory beep

  FatigueLevel _level = FatigueLevel.normal;
  Timer? _repeat;
  int _generation = 0; // bumps on every change, so old beep loops stop

  bool get alarmActive => _level != FatigueLevel.normal;

  /// Call whenever the level, or whether alarms are allowed, changes.
  /// Pass FatigueLevel.normal to silence.
  Future<void> setLevel(FatigueLevel level) async {
    if (level == _level) return;
    _level = level;
    _repeat?.cancel();
    _repeat = null;
    final gen = ++_generation;
    await _alarmPlayer.stop();

    switch (level) {
      case FatigueLevel.normal:
        return;
      case FatigueLevel.warning:
        _repeatBeeps(kWarningBeeps, gen);
      case FatigueLevel.high:
        _repeatBeeps(kHighBeeps, gen);
      case FatigueLevel.critical:
        await _alarmPlayer.setReleaseMode(ReleaseMode.loop);
        await _alarmPlayer.setVolume(1.0);
        await _alarmPlayer.play(AssetSource(_alarm));
    }
  }

  /// One beep for an advisory. Skipped while a fatigue alarm is sounding.
  Future<void> advisoryBeep() async {
    if (alarmActive) return;
    await _advisoryPlayer.setReleaseMode(ReleaseMode.stop);
    await _advisoryPlayer.setVolume(1.0);
    await _advisoryPlayer.play(AssetSource(_beep));
  }

  void _repeatBeeps(int count, int gen) {
    _beeps(count, gen);
    _repeat = Timer.periodic(kBeepRepeatEvery, (_) => _beeps(count, gen));
  }

  Future<void> _beeps(int count, int gen) async {
    await _alarmPlayer.setReleaseMode(ReleaseMode.stop);
    await _alarmPlayer.setVolume(1.0);
    for (var i = 0; i < count; i++) {
      if (gen != _generation) return; // level changed meanwhile
      await _alarmPlayer.stop();
      await _alarmPlayer.play(AssetSource(_beep));
      await Future.delayed(kBeepLength + kBeepGap);
    }
  }

  void dispose() {
    _generation++;
    _repeat?.cancel();
    _alarmPlayer.dispose();
    _advisoryPlayer.dispose();
  }
}
