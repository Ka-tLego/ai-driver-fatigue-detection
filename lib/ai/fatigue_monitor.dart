//AI & Computer Vision
//
// Turns live camera frames into:
//   pilotDetected, blinkRate, eyeAspectRatio, fatigueLevel

import 'dart:io';
import 'dart:math';
import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

// Moved here from main.dart so both files can use it.
enum FatigueLevel { normal, warning, high, critical }

// ======================================
// TUNING CONSTANTS (adjust while testing)
// ======================================
const int kCalibrationMs = 5000; // look at camera, eyes open
const double kClosedRatio = 0.72; // closed if EAR < baseline * this
const double kFallbackEarThreshold = 0.20;
const int kMinBlinkMs = 60; // shorter = noise
const int kMaxBlinkMs = 700; // longer = eye closure, not a blink
const int kNoFaceMs = 1000; // lost face this long = no pilot
const int kWindowSec = 60; // blink rate / PERCLOS window

class _Sample {
  final DateTime time;
  final bool closed;
  _Sample(this.time, this.closed);
}

class FatigueMonitor extends ChangeNotifier {
  // ---------- OUTPUTS (read these from the UI) ----------
  bool pilotDetected = false;
  int blinkRate = 0; // blinks per minute
  double eyeAspectRatio = 0.0;
  FatigueLevel fatigueLevel = FatigueLevel.normal;

  // ---------- EXTRA INFO (optional for UI / backend) ----------
  bool calibrating = true;
  double perclos = 0.0; // fraction of time eyes closed (last 60 s)
  double closureSeconds = 0.0; // current continuous eye closure

  // ---------- INTERNALS ----------
  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableContours: true,
      enableClassification: true,
      performanceMode: FaceDetectorMode.fast,
      minFaceSize: 0.2,
    ),
  );

  CameraController? _controller;
  CameraDescription? _camera;
  bool _busy = false;
  bool _disposed = false;

  DateTime? _lastFaceTime;
  DateTime? _calibStart;
  final List<double> _calibEars = [];
  double? _baseline;
  double _threshold = kFallbackEarThreshold;
  DateTime? _statsStart;

  DateTime? _closedSince;
  DateTime? _headDownSince;
  DateTime? _lowerSince;
  final List<DateTime> _blinks = [];
  final List<_Sample> _samples = [];

  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  static const Map<DeviceOrientation, int> _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  // ======================================
  // START / STOP
  // ======================================

  /// Call after the CameraController is initialised.
  Future<void> start(CameraController controller, CameraDescription camera) async {
    _controller = controller;
    _camera = camera;
    await controller.startImageStream(_onFrame);
  }

  /// Restart calibration (e.g. a "Recalibrate" button).
  void recalibrate() {
    _baseline = null;
    _calibStart = null;
    _calibEars.clear();
    calibrating = true;
    _resetStats();
  }

  @override
  void dispose() {
    _disposed = true;
    _detector.close();
    super.dispose();
  }

  // ======================================
  // FRAME PROCESSING
  // ======================================

  Future<void> _onFrame(CameraImage image) async {
    if (_busy || _disposed) return; // drop frames while busy
    _busy = true;
    try {
      final input = _toInputImage(image);
      if (input == null) return;
      final faces = await _detector.processImage(input);
      if (_disposed) return;
      _update(faces, DateTime.now());
    } catch (e) {
      debugPrint('FatigueMonitor error: $e');
    } finally {
      _busy = false;
    }
  }

  InputImage? _toInputImage(CameraImage image) {
    final camera = _camera;
    final controller = _controller;
    if (camera == null || controller == null) return null;

    final sensorOrientation = camera.sensorOrientation;
    InputImageRotation? rotation;

    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      var comp = _orientations[controller.value.deviceOrientation];
      if (comp == null) return null;
      if (camera.lensDirection == CameraLensDirection.front) {
        comp = (sensorOrientation + comp) % 360;
      } else {
        comp = (sensorOrientation - comp + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(comp);
    }
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null ||
        (Platform.isAndroid && format != InputImageFormat.nv21) ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) {
      return null;
    }
    if (image.planes.length != 1) return null;
    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  // ======================================
  // EAR
  // ======================================

  double _dist(Point<int> a, Point<int> b) =>
      sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2));

  /// EAR from an ML Kit eye contour (16 points: 0 and 8 are the corners,
  /// 1-7 the upper lid, 9-15 the lower lid).
  double? _eyeEar(FaceContour? contour) {
    final p = contour?.points;
    if (p == null || p.length < 16) return null;
    final horizontal = _dist(p[0], p[8]);
    if (horizontal == 0) return null;
    final vertical =
        (_dist(p[3], p[13]) + _dist(p[4], p[12]) + _dist(p[5], p[11])) / 3;
    return vertical / horizontal;
  }

  // ======================================
  // MAIN LOGIC
  // ======================================

  void _update(List<Face> faces, DateTime now) {
    if (faces.isEmpty) {
      _handleNoFace(now);
      return;
    }

    // The pilot = largest face in view.
    faces.sort((a, b) => (b.boundingBox.width * b.boundingBox.height)
        .compareTo(a.boundingBox.width * a.boundingBox.height));
    final face = faces.first;

    _lastFaceTime = now;
    pilotDetected = true;

    // ----- EAR -----
    final ears = <double>[
      if (_eyeEar(face.contours[FaceContourType.leftEye]) != null)
        _eyeEar(face.contours[FaceContourType.leftEye])!,
      if (_eyeEar(face.contours[FaceContourType.rightEye]) != null)
        _eyeEar(face.contours[FaceContourType.rightEye])!,
    ];
    final double? ear =
        ears.isEmpty ? null : ears.reduce((a, b) => a + b) / ears.length;

    // ML Kit's own eye-open probability = backup signal
    final probs = <double>[
      if (face.leftEyeOpenProbability != null) face.leftEyeOpenProbability!,
      if (face.rightEyeOpenProbability != null) face.rightEyeOpenProbability!,
    ];
    final double? openProb =
        probs.isEmpty ? null : probs.reduce((a, b) => a + b) / probs.length;

    if (ear == null && openProb == null) {
      _notify(now);
      return;
    }
    eyeAspectRatio = ear ?? eyeAspectRatio;

    // ----- Calibration (learn this pilot's open-eye EAR) -----
    if (_baseline == null) {
      calibrating = true;
      _calibStart ??= now;
      if (ear != null && (openProb == null || openProb > 0.5)) {
        _calibEars.add(ear);
      }
      if (now.difference(_calibStart!).inMilliseconds >= kCalibrationMs &&
          _calibEars.length >= 20) {
        _calibEars.sort();
        _baseline = _calibEars[(_calibEars.length * 0.8).floor()];
        _threshold = _baseline! * kClosedRatio;
        calibrating = false;
        _statsStart = now;
        debugPrint('EAR baseline=$_baseline threshold=$_threshold');
      }
      fatigueLevel = FatigueLevel.normal;
      _notify(now);
      return;
    }

    // ----- Eye closed? -----
    final closed = (ear != null && ear < _threshold) ||
        (openProb != null && openProb < 0.2);

    // ----- Blink / closure tracking -----
    if (closed) {
      _closedSince ??= now;
    } else if (_closedSince != null) {
      final ms = now.difference(_closedSince!).inMilliseconds;
      if (ms >= kMinBlinkMs && ms <= kMaxBlinkMs) _blinks.add(now);
      _closedSince = null;
    }
    closureSeconds = _closedSince == null
        ? 0.0
        : now.difference(_closedSince!).inMilliseconds / 1000.0;

    // ----- Head nod (head dropping down) -----
    final pitch = face.headEulerAngleX;
    if (pitch != null && pitch < -20) {
      _headDownSince ??= now;
    } else {
      _headDownSince = null;
    }
    final headDownSec = _headDownSince == null
        ? 0.0
        : now.difference(_headDownSince!).inMilliseconds / 1000.0;

    // ----- Sliding window: PERCLOS + blink rate -----
       final cutoff = now.subtract(const Duration(seconds: kWindowSec));
    final perclosCutoff = now.subtract(const Duration(seconds: 15));
    _samples.add(_Sample(now, closed));
    _samples.removeWhere((s) => s.time.isBefore(perclosCutoff));
    _blinks.removeWhere((t) => t.isBefore(cutoff));

    final windowSec = min(kWindowSec.toDouble(),
        now.difference(_statsStart ?? now).inMilliseconds / 1000.0);
    final closedCount = _samples.where((s) => s.closed).length;
    perclos = _samples.isEmpty ? 0.0 : closedCount / _samples.length;
    blinkRate = windowSec >= 15 ? (_blinks.length * 60 / windowSec).round() : 0;

    // ----- Classify -----
    var target = FatigueLevel.normal;
    void raise(FatigueLevel l) {
      if (l.index > target.index) target = l;
    }

    // continuous eye closure (microsleep)
    if (closureSeconds >= 2.0) {
      raise(FatigueLevel.critical);
    } else if (closureSeconds >= 1.2) {
      raise(FatigueLevel.high);
    } else if (closureSeconds >= 0.7) {
      raise(FatigueLevel.warning);
    }

    // PERCLOS (needs ~10 s of data)
        // PERCLOS over the last 15 s
    if (windowSec >= 10) {
      if (perclos >= 0.40) {
        raise(FatigueLevel.high);
      } else if (perclos >= 0.25) {
        raise(FatigueLevel.warning);
      }
    }

    // very high blink rate only
    if (windowSec >= 30 && blinkRate > 28) {
      raise(FatigueLevel.warning);
    }
    // head nodding down
    if (headDownSec >= 2.5) {
      raise(FatigueLevel.high);
    } else if (headDownSec >= 1.5) {
      raise(FatigueLevel.warning);
    }

    // Escalate instantly, de-escalate only after 3 s (stops flicker).
    if (target.index >= fatigueLevel.index) {
      fatigueLevel = target;
      _lowerSince = null;
    } else {
      _lowerSince ??= now;
      if (now.difference(_lowerSince!).inMilliseconds >= 1000) {
        fatigueLevel = target;
        _lowerSince = null;
      }
    }

    _notify(now);
  }

  void _handleNoFace(DateTime now) {
    final last = _lastFaceTime;
    if (last == null || now.difference(last).inMilliseconds >= kNoFaceMs) {
      pilotDetected = false;
      eyeAspectRatio = 0.0;
      fatigueLevel = FatigueLevel.normal;
      closureSeconds = 0.0;
      _closedSince = null;
      _headDownSince = null;
      _lowerSince = null;
      _notify(now);
    }
  }

  void _resetStats() {
    _blinks.clear();
    _samples.clear();
    _closedSince = null;
    blinkRate = 0;
    perclos = 0.0;
  }

  void _notify(DateTime now) {
    if (_disposed) return;
    if (now.difference(_lastNotify).inMilliseconds < 100) return; // ~10 Hz
    _lastNotify = now;
    notifyListeners();
  }
}
