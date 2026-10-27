//AI & Computer Vision
//
// Turns live camera frames into:
//   pilotDetected, blinkRate, eyeAspectRatio, fatigueLevel, fatigueScore
//
// This file handles the camera and ML Kit face detection; the fatigue score
// itself (how signals build up over time) lives in fatigue_estimator.dart.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../sim/fatigue_simulator.dart';
import 'fatigue_estimator.dart';

export 'fatigue_estimator.dart' show FatigueLevel;

// ======================================
// TUNING CONSTANTS (adjust while testing)
// ======================================
const int kCalibrationMs = 5000; // look at camera, eyes open, mouth closed
const double kClosedRatio = 0.72; // closed if EAR < baseline * this
const double kFallbackEarThreshold = 0.20;
const int kNoFaceMs = 1000; // lost face this long = no pilot

class FatigueMonitor extends ChangeNotifier {
  // ---------- OUTPUTS (read these from the UI) ----------
  bool pilotDetected = false;
  int blinkRate = 0; // blinks per minute
  double eyeAspectRatio = 0.0;
  FatigueLevel fatigueLevel = FatigueLevel.normal;

  // ---------- EXTRA INFO (optional for UI / backend) ----------
  bool calibrating = true;
  double fatigueScore = 0.0; // 0-100, builds up and wears off over time
  String fatigueReason = ''; // main cause, e.g. "frequent yawning"
  double perclos = 0.0; // fraction of the last minute with eyes closed
  double closureSeconds = 0.0; // current eye closure (yawns excluded)
  double lastClosureSeconds = 0.0; // most recent completed eye closure
  double mouthRatio = 0.0; // mouth opening height / width
  bool yawning = false;
  int recentYawns = 0; // last 10 min

  /// Latest heart rate from the HR strap (set by the UI; null = none).
  int? heartRateBpm;

  // ---------- INTERNALS ----------
  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableContours: true,
      enableClassification: true,
      performanceMode: FaceDetectorMode.fast,
      minFaceSize: 0.2,
    ),
  );
  final FatigueEstimator _estimator = FatigueEstimator();

  // ---------- SIMULATION (menu) ----------
  FatigueSimulator? _sim;
  FatigueEstimator? _simEstimator; // separate, so real history is untouched
  Timer? _simTimer;
  String simulationPhase = '';
  int? simulationSecondsLeft;

  bool get isSimulating => _sim != null;
  SimScenario? get simulationScenario => _sim?.scenario;

  CameraController? _controller;
  CameraDescription? _camera;
  bool _busy = false;
  bool _disposed = false;

  DateTime? _lastFaceTime;
  DateTime? _calibStart;
  final List<double> _calibEars = [];
  final List<double> _calibMouths = [];
  double? _baseline;
  double _threshold = kFallbackEarThreshold;

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

  /// Stop processing frames (e.g. app paused). Call before disposing the
  /// CameraController. Calibration restarts on the next start(); the fatigue
  /// history is kept (call resetFatigue() for a new drive).
  Future<void> stop() async {
    stopSimulation();
    final controller = _controller;
    _controller = null;
    _camera = null;
    if (controller != null && controller.value.isStreamingImages) {
      await controller.stopImageStream();
    }
    pilotDetected = false;
    eyeAspectRatio = 0.0;
    _lastFaceTime = null;
    _estimator.onFaceLost();
    recalibrate();
  }

  /// Restart calibration (e.g. a "Recalibrate" button). Keeps the fatigue
  /// history.
  void recalibrate() {
    _baseline = null;
    _calibStart = null;
    _calibEars.clear();
    _calibMouths.clear();
    calibrating = true;
    _copyOutputs();
  }

  /// Forget all built-up fatigue (start of a new drive).
  void resetFatigue() {
    _estimator.reset();
    _copyOutputs();
  }

  @override
  void dispose() {
    _disposed = true;
    _simTimer?.cancel();
    _detector.close();
    super.dispose();
  }

  // ======================================
  // SIMULATION
  // Feeds made-up measurements into a fatigue estimator 10x per second
  // instead of camera frames. Uses compressed memory so the driver can
  // build up and recover within about a minute.
  // ======================================

  void startSimulation(SimScenario scenario) {
    stopSimulation();
    _sim = FatigueSimulator(scenario);
    _simEstimator = FatigueEstimator(tuning: FatigueTuning.simulation);
    calibrating = false;
    _simTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final sim = _sim;
      final est = _simEstimator;
      if (sim == null || est == null || _disposed) return;
      final now = DateTime.now();
      final frame = sim.next(now, est.level);
      est.update(frame.observation);
      pilotDetected = true;
      eyeAspectRatio = frame.ear;
      mouthRatio = frame.observation.mouthRatio ?? 0;
      simulationPhase = frame.phase;
      simulationSecondsLeft = frame.secondsLeft;
      _copyOutputs();
      _notify(now);
    });
  }

  void stopSimulation() {
    if (_sim == null) return;
    _simTimer?.cancel();
    _simTimer = null;
    _sim = null;
    _simEstimator = null;
    simulationPhase = '';
    simulationSecondsLeft = null;
    pilotDetected = false;
    eyeAspectRatio = 0.0;
    recalibrate(); // back to the camera: relearn the pilot's eyes
    if (!_disposed) notifyListeners();
  }

  // ======================================
  // FRAME PROCESSING
  // ======================================

  Future<void> _onFrame(CameraImage image) async {
    if (_busy || _disposed || isSimulating) return; // drop frames while busy
    _busy = true;
    try {
      final input = _toInputImage(image);
      if (input == null) return;
      final faces = await _detector.processImage(input);
      if (_disposed || _controller == null) return; // stopped meanwhile
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
  // EAR / MOUTH
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

  /// Mouth opening: gap between the inner lips (middle points) divided by
  /// the mouth width (outer lip corners). ~0 closed, ~0.6+ for a yawn.
  double? _mouthRatio(Face face) {
    final outer = face.contours[FaceContourType.upperLipTop]?.points;
    final upperInner = face.contours[FaceContourType.upperLipBottom]?.points;
    final lowerInner = face.contours[FaceContourType.lowerLipTop]?.points;
    if (outer == null || upperInner == null || lowerInner == null) return null;
    if (outer.length < 2 || upperInner.isEmpty || lowerInner.isEmpty) return null;
    final width = _dist(outer.first, outer.last);
    if (width == 0) return null;
    final gap = _dist(
      upperInner[upperInner.length ~/ 2],
      lowerInner[lowerInner.length ~/ 2],
    );
    return gap / width;
  }

  double? _average(List<double?> values) {
    final v = values.whereType<double>().toList();
    return v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
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

    final ear = _average([
      _eyeEar(face.contours[FaceContourType.leftEye]),
      _eyeEar(face.contours[FaceContourType.rightEye]),
    ]);
    // ML Kit's own eye-open probability = backup signal
    final openProb = _average([
      face.leftEyeOpenProbability,
      face.rightEyeOpenProbability,
    ]);
    final mouth = _mouthRatio(face);
    if (mouth != null) mouthRatio = mouth;

    if (ear == null && openProb == null) {
      _notify(now);
      return;
    }
    eyeAspectRatio = ear ?? eyeAspectRatio;

    // ----- Calibration (learn this pilot's open-eye EAR and resting mouth) -----
    if (_baseline == null) {
      calibrating = true;
      _calibStart ??= now;
      if (ear != null && (openProb == null || openProb > 0.5)) {
        _calibEars.add(ear);
      }
      if (mouth != null) _calibMouths.add(mouth);
      if (now.difference(_calibStart!).inMilliseconds >= kCalibrationMs &&
          _calibEars.length >= 20) {
        _calibEars.sort();
        _baseline = _calibEars[(_calibEars.length * 0.8).floor()];
        _threshold = _baseline! * kClosedRatio;
        if (_calibMouths.isNotEmpty) {
          _calibMouths.sort();
          _estimator.setMouthBaseline(_calibMouths[_calibMouths.length ~/ 2]);
        }
        calibrating = false;
        debugPrint('EAR baseline=$_baseline threshold=$_threshold');
      }
      fatigueLevel = FatigueLevel.normal;
      _notify(now);
      return;
    }

    // ----- Feed the fatigue estimator -----
    final closed = (ear != null && ear < _threshold) ||
        (openProb != null && openProb < 0.2);
    _estimator.update(FrameObservation(
      time: now,
      eyesClosed: closed,
      mouthRatio: mouth,
      headPitch: face.headEulerAngleX,
      heartRateBpm: heartRateBpm,
    ));
    _copyOutputs();
    _notify(now);
  }

  void _copyOutputs() {
    final e = _simEstimator ?? _estimator;
    fatigueLevel = calibrating ? FatigueLevel.normal : e.level;
    fatigueScore = e.score;
    fatigueReason = e.reason;
    blinkRate = e.blinkRate;
    perclos = e.perclos;
    closureSeconds = e.closureSeconds;
    lastClosureSeconds = e.lastClosureSeconds;
    yawning = e.yawning;
    recentYawns = e.recentYawns;
  }

  void _handleNoFace(DateTime now) {
    final last = _lastFaceTime;
    if (last == null || now.difference(last).inMilliseconds >= kNoFaceMs) {
      pilotDetected = false;
      eyeAspectRatio = 0.0;
      // Keep the fatigue history (score, yawns...) but drop what was in
      // progress; no alarm while nobody is in view.
      _estimator.onFaceLost();
      _copyOutputs();
      fatigueLevel = FatigueLevel.normal;
      _notify(now);
    }
  }

  void _notify(DateTime now) {
    if (_disposed) return;
    if (now.difference(_lastNotify).inMilliseconds < 100) return; // ~10 Hz
    _lastNotify = now;
    notifyListeners();
  }
}
