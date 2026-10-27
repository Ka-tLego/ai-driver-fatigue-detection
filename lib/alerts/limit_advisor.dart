// Driving-limit advisories
//
// The backend learns from past drives when fatigue becomes likely (see the
// dashboard): a recommended break interval and "danger zones" (hour of day
// x time into the drive). This warns the driver shortly before reaching
// them, and when they're reached. Each advisory is shown once per drive.

import 'dart:math';

const Duration kAdvisoryLookAhead = Duration(minutes: 10);

class DangerZone {
  final int hour; // local hour of day (backend time zone)
  final int driveStartMin;
  final int? driveEndMin; // null = no upper limit
  final double? ratio; // x the average fatigue rate
  final String label; // e.g. "02:00–03:00 after 3h+ of driving"

  const DangerZone({
    required this.hour,
    required this.driveStartMin,
    required this.driveEndMin,
    required this.ratio,
    required this.label,
  });

  factory DangerZone.fromJson(Map<String, dynamic> j) => DangerZone(
        hour: (j['hour'] as num).toInt(),
        driveStartMin: (j['driveStartMin'] as num).toInt(),
        driveEndMin: (j['driveEndMin'] as num?)?.toInt(),
        ratio: (j['ratio'] as num?)?.toDouble(),
        label: j['label'] as String,
      );

  bool contains(int localHour, double driveMinutes) =>
      localHour == hour &&
      driveMinutes >= driveStartMin &&
      (driveEndMin == null || driveMinutes < driveEndMin!);
}

class DrivingLimits {
  final int? breakEveryMinutes;
  final int utcOffsetMinutes; // backend time zone (e.g. +120 for SAST)
  final List<DangerZone> zones;

  const DrivingLimits({
    required this.breakEveryMinutes,
    required this.utcOffsetMinutes,
    required this.zones,
  });

  factory DrivingLimits.fromJson(Map<String, dynamic> j) => DrivingLimits(
        breakEveryMinutes: (j['breakEveryMinutes'] as num?)?.toInt(),
        utcOffsetMinutes: (j['utcOffsetMinutes'] as num? ?? 0).toInt(),
        zones: [
          for (final z in (j['dangerZones'] as List? ?? []))
            DangerZone.fromJson(z as Map<String, dynamic>),
        ],
      );
}

class Advisory {
  final String key; // identifies it, so it's shown only once per drive
  final String message;
  const Advisory(this.key, this.message);
}

String _duration(int min) {
  final h = min ~/ 60;
  final m = min % 60;
  if (h == 0) return '$m min';
  return m == 0 ? '$h h' : '$h h $m min';
}

class LimitAdvisor {
  final Set<String> _shown = {};

  /// Call at the start of each drive.
  void reset() => _shown.clear();

  /// Advisories due now that haven't been shown yet this drive.
  List<Advisory> check(DrivingLimits limits, DateTime driveStart, DateTime now) {
    final due = <Advisory>[];
    void add(String key, String message) {
      if (_shown.add(key)) due.add(Advisory(key, message));
    }

    final elapsed = now.difference(driveStart).inSeconds / 60.0;
    final ahead = kAdvisoryLookAhead.inMinutes;

    // ----- Recommended break -----
    final every = limits.breakEveryMinutes;
    if (every != null && every > 0) {
      final next = (elapsed / every).floor() + 1; // next break number
      final untilNext = next * every - elapsed;
      if (elapsed >= every) {
        final reached = (elapsed / every).floor();
        add('break-$reached',
            'Break time reached: ${_duration(reached * every)} of driving. Plan a rest stop.');
      }
      if (untilNext <= ahead) {
        add('break-soon-$next',
            'Break recommended in ${max(1, untilNext.ceil())} min (every ${_duration(every)}).');
      }
    }

    // ----- Danger zones -----
    final localNow = now.toUtc().add(Duration(minutes: limits.utcOffsetMinutes));
    final localSoon = localNow.add(kAdvisoryLookAhead);
    for (final z in limits.zones) {
      final id = '${z.hour}-${z.driveStartMin}';
      if (z.contains(localNow.hour, elapsed)) {
        _shown.add('zone-soon-$id'); // no "soon" after it has started
        add('zone-now-$id', 'High-risk period now (${z.label}). Stay alert and consider a break.');
      } else if (z.contains(localSoon.hour, elapsed + ahead)) {
        add('zone-soon-$id', 'High-risk period in about $ahead min (${z.label}).');
      }
    }
    return due;
  }
}
