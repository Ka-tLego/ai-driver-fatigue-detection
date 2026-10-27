// Unit tests for decoding BLE Heart Rate Measurement (0x2A37) packets.

import 'package:flutter_test/flutter_test.dart';

import 'package:pilot_fatigue_app/sensors/heart_rate_monitor.dart';

void main() {
  test('8-bit heart rate', () {
    expect(HeartRateMonitor.parseHeartRate([0x00, 72]), 72);
  });

  test('16-bit heart rate (little endian)', () {
    expect(HeartRateMonitor.parseHeartRate([0x01, 0x2C, 0x01]), 300);
  });

  test('extra fields after the value are ignored', () {
    expect(HeartRateMonitor.parseHeartRate([0x16, 85, 0x10, 0x03]), 85);
  });

  test('0 BPM or short packets give no reading', () {
    expect(HeartRateMonitor.parseHeartRate([0x00, 0]), isNull);
    expect(HeartRateMonitor.parseHeartRate([0x00]), isNull);
    expect(HeartRateMonitor.parseHeartRate([0x01, 0x48]), isNull);
  });
}
