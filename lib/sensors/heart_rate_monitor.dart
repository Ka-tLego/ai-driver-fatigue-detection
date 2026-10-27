// Chest strap heart rate over Bluetooth Low Energy
//
// Connects to the pilot's Garmin HR strap (HRM-Dual / Pro / Pro Plus / 600 /
// Fit). These straps broadcast on ANT+ and Bluetooth at the same time; the
// app uses the Bluetooth side, which every phone supports.
//
// Any strap offering the standard BLE Heart Rate Service (0x180D /
// characteristic 0x2A37) will work, so no pairing or name setup is needed.
//
// Outputs:
//   heartRate (BPM, null = no reading), status, strapName

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

enum StrapStatus {
  unsupported, // phone has no Bluetooth LE
  bluetoothOff,
  searching,
  connecting,
  connected,
}

// ======================================
// SETTINGS
// ======================================
const Duration kScanTimeout = Duration(seconds: 10);
const Duration kRetryDelay = Duration(seconds: 5);

final Guid _hrService = Guid('180D');
final Guid _hrMeasurement = Guid('2A37');

class HeartRateMonitor extends ChangeNotifier {
  // ---------- OUTPUTS (read these from the UI) ----------
  int? heartRate;
  StrapStatus status = StrapStatus.searching;
  String? strapName;

  bool get connected => status == StrapStatus.connected;

  // ---------- INTERNALS ----------
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  BluetoothDevice? _device;
  bool _looping = false;
  bool _disposed = false;

  // ======================================
  // START / STOP
  // ======================================

  Future<void> start() async {
    if (!await FlutterBluePlus.isSupported) {
      _set(StrapStatus.unsupported);
      return;
    }

    // Reconnect whenever Bluetooth is switched back on.
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on) {
        _connectLoop();
      } else if (state == BluetoothAdapterState.off) {
        heartRate = null;
        _set(StrapStatus.bluetoothOff);
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _adapterSub?.cancel();
    FlutterBluePlus.stopScan();
    _device?.disconnect();
    super.dispose();
  }

  // ======================================
  // FIND + CONNECT (keeps retrying)
  // ======================================

  Future<void> _connectLoop() async {
    if (_looping) return;
    _looping = true;
    try {
      while (!_disposed &&
          FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on) {
        _set(StrapStatus.searching);
        final device = await _findStrap();

        if (device != null) await _connectAndListen(device);
        await Future.delayed(kRetryDelay);
      }
    } finally {
      _looping = false;
    }
  }

  Future<BluetoothDevice?> _findStrap() async {
    // 1. A strap already connected to the phone won't advertise, so check
    //    those first.
    try {
      final system = await FlutterBluePlus.systemDevices([_hrService]);
      if (system.isNotEmpty) return system.first;
    } catch (e) {
      debugPrint('HeartRateMonitor systemDevices error: $e');
    }

    // 2. Otherwise scan for anything advertising heart rate. The strap only
    //    wakes up and advertises while it's being worn.
    final found = Completer<BluetoothDevice?>();
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      if (results.isEmpty || found.isCompleted) return;
      // Strongest signal = the strap closest to the phone.
      final best = results.reduce((a, b) => a.rssi >= b.rssi ? a : b);
      found.complete(best.device);
    });

    try {
      await FlutterBluePlus.startScan(
        withServices: [_hrService],
        timeout: kScanTimeout,
      );
      await FlutterBluePlus.isScanning.where((s) => !s).first;
    } catch (e) {
      debugPrint('HeartRateMonitor scan error: $e');
    } finally {
      await sub.cancel();
    }

    if (found.isCompleted) {
      await FlutterBluePlus.stopScan();
      return found.future;
    }
    return null;
  }

  /// Connects, streams heart rate, and returns once the strap disconnects.
  Future<void> _connectAndListen(BluetoothDevice device) async {
    _device = device;
    strapName = device.platformName;
    _set(StrapStatus.connecting);

    try {
      // License.nonprofit: this is an educational project.
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
        mtu: null,
      );

      final services = await device.discoverServices();
      BluetoothCharacteristic? hrChar;
      for (final s in services) {
        if (s.uuid != _hrService) continue;
        for (final c in s.characteristics) {
          if (c.uuid == _hrMeasurement) hrChar = c;
        }
      }

      if (hrChar == null) {
        await device.disconnect();
        return;
      }

      final sub = hrChar.onValueReceived.listen((data) {
        heartRate = parseHeartRate(data);
        _notify();
      });
      device.cancelWhenDisconnected(sub);
      await hrChar.setNotifyValue(true);

      _set(StrapStatus.connected);

      await device.connectionState
          .where((s) => s == BluetoothConnectionState.disconnected)
          .first;
    } catch (e) {
      debugPrint('HeartRateMonitor connect error: $e');
      try {
        await device.disconnect();
      } catch (_) {}
    }

    heartRate = null;
    _notify();
  }

  // ======================================
  // PARSING
  // ======================================

  /// Decodes a Heart Rate Measurement (0x2A37) packet.
  /// Byte 0 = flags (bit 0: 16-bit value), then the BPM value.
  /// Returns null for 0 BPM (strap not on the chest).
  static int? parseHeartRate(List<int> data) {
    if (data.length < 2) return null;
    final is16Bit = (data[0] & 0x01) != 0;
    if (is16Bit && data.length < 3) return null;
    final bpm = is16Bit ? data[1] | (data[2] << 8) : data[1];
    return bpm == 0 ? null : bpm;
  }

  void _set(StrapStatus s) {
    status = s;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
