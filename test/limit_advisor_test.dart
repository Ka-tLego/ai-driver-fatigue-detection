// Driving-limit advisories: break due and high-risk periods.

import 'package:flutter_test/flutter_test.dart';

import 'package:pilot_fatigue_app/alerts/limit_advisor.dart';

void main() {
  // Backend time zone SAST (UTC+2). Drive starts 10:00 SAST = 08:00 UTC.
  final start = DateTime.utc(2026, 10, 28, 8);
  DateTime at(int minutes) => start.add(Duration(minutes: minutes));

  const limits = DrivingLimits(
    breakEveryMinutes: 75,
    utcOffsetMinutes: 120,
    zones: [
      // 13:00-14:00 SAST, after 3h+ of driving
      DangerZone(hour: 13, driveStartMin: 180, driveEndMin: null, ratio: 3.2, label: '13:00–14:00 after 3h+ of driving'),
    ],
  );

  List<String> keys(List<Advisory> a) => a.map((x) => x.key).toList();

  test('nothing early in the drive', () {
    expect(LimitAdvisor().check(limits, start, at(30)), isEmpty);
  });

  test('break: warns 10 minutes before, then when reached, each once', () {
    final advisor = LimitAdvisor();
    final soon = advisor.check(limits, start, at(66));
    expect(keys(soon), ['break-soon-1']);
    expect(soon.single.message, contains('Break recommended in 9 min'));

    expect(advisor.check(limits, start, at(70)), isEmpty, reason: 'shown only once');

    final due = advisor.check(limits, start, at(75));
    expect(keys(due), ['break-1']);
    expect(due.single.message, contains('1 h 15 min of driving'));

    expect(keys(advisor.check(limits, start, at(141))), ['break-soon-2']);
    expect(keys(advisor.check(limits, start, at(150))), ['break-2']);
  });

  test('high-risk period: warns about 10 minutes ahead, then when it starts', () {
    final advisor = LimitAdvisor();
    // 12:52 SAST, 172 min into the drive: in 10 min it is 13:02 and 182 min
    final soon = advisor.check(limits, start, at(172));
    expect(keys(soon).where((k) => k.startsWith('zone')), ['zone-soon-13-180']);
    expect(soon.firstWhere((a) => a.key.startsWith('zone')).message, contains('13:00–14:00'));

    final now = advisor.check(limits, start, at(181)); // 13:01 SAST, 181 min
    expect(keys(now).where((k) => k.startsWith('zone')), ['zone-now-13-180']);
    expect(advisor.check(limits, start, at(190)).where((a) => a.key.startsWith('zone')), isEmpty);
  });

  test('a zone is not flagged when the drive is too short for it', () {
    final advisor = LimitAdvisor();
    final lateStart = DateTime.utc(2026, 10, 28, 10, 30); // 12:30 SAST
    // 13:05 SAST but only 35 min into the drive
    final a = advisor.check(limits, lateStart, lateStart.add(const Duration(minutes: 35)));
    expect(a.where((x) => x.key.startsWith('zone')), isEmpty);
  });

  test('reset() allows advisories again for a new drive', () {
    final advisor = LimitAdvisor();
    expect(advisor.check(limits, start, at(66)), isNotEmpty);
    advisor.reset();
    expect(advisor.check(limits, start, at(66)), isNotEmpty);
  });

  test('built-in demo limits drive the simulations when the backend has none', () {
    final advisor = LimitAdvisor();
    const demo = DrivingLimits.demo;
    expect(demo.breakEveryMinutes, 75);
    expect(demo.zones.first.label, contains('02:00'));
    // 12 min before the break, run forward: "in 10 min", then "reached"
    expect(keys(advisor.check(demo, start, at(66))), contains('break-soon-1'));
    expect(keys(advisor.check(demo, start, at(75))), contains('break-1'));
  });

  test('parses the backend response', () {
    final l = DrivingLimits.fromJson({
      'breakEveryMinutes': 75,
      'utcOffsetMinutes': 120,
      'dangerZones': [
        {'hour': 2, 'driveStartMin': 180, 'driveEndMin': null, 'ratio': 4.7, 'label': '02:00–03:00 after 3h+ of driving'},
      ],
    });
    expect(l.breakEveryMinutes, 75);
    expect(l.zones.single.contains(2, 200), isTrue);
    expect(l.zones.single.contains(2, 100), isFalse);
    expect(DrivingLimits.fromJson({'breakEveryMinutes': null, 'dangerZones': []}).zones, isEmpty);
  });
}
