import 'dart:async';
import 'dart:io';
 
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:audioplayers/audioplayers.dart';
 
import 'ai/fatigue_monitor.dart'; // Member 4: AI & computer vision
import 'sensors/heart_rate_monitor.dart'; // Garmin HR strap (Bluetooth)
import 'services/backend_service.dart'; // REST backend
 
late List<CameraDescription> cameras;

// A pause longer than this (app in the background) starts a new drive.
const Duration kNewDriveAfter = Duration(minutes: 5);
// A fatigue episode ends after this long back at normal.
const Duration kEpisodeResetAfter = Duration(seconds: 10);
// Events kept while the backend is unreachable.
const int kMaxPendingEvents = 200;

/// One monitoring session ("drive"). Created when monitoring starts and
/// registered with the backend once it's reachable.
class _Drive {
  final DateTime startedAt;
  String? id; // backend session ID
  _Drive(this.startedAt);
}

/// A fatigue event waiting to be sent to the backend.
class _PendingEvent {
  final _Drive drive;
  final FatigueLevel level;
  final DateTime occurredAt;
  final int? heartRateBpm;
  final int blinkRatePerMinute;
  final double ear;
  final double closureSeconds;

  _PendingEvent({
    required this.drive,
    required this.level,
    required this.occurredAt,
    required this.heartRateBpm,
    required this.blinkRatePerMinute,
    required this.ear,
    required this.closureSeconds,
  });
}
 
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
 
  cameras = await availableCameras();
 
  runApp(const PilotFatigueApp());
}
 
class PilotFatigueApp extends StatelessWidget {
  const PilotFatigueApp({super.key});
 
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Pilot Fatigue Monitor',
      theme: ThemeData.dark(),
      home: const DashboardScreen(),
    );
  }
}
 
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
 
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}
 
class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  CameraController? controller;
 
  // Member 4: AI / computer vision
  final FatigueMonitor monitor = FatigueMonitor();

  // Heart rate from the Garmin chest strap over Bluetooth
  final HeartRateMonitor heartMonitor = HeartRateMonitor();

  // Backend: readings and events are sent every few seconds (see _syncBackend)
  final BackendService backendService = BackendService();
  _Drive? _drive;
  DateTime? _pausedAt;
  final List<_PendingEvent> _pendingEvents = [];
  FatigueLevel _episodeLevel = FatigueLevel.normal;
  DateTime? _normalSince;
  Timer? _backendTimer;
  bool _backendBusy = false;
  bool? _backendOnline; // null = not tried yet
 
  // Audio player
  final AudioPlayer alertPlayer = AudioPlayer();
 
  // ======================================
  // VALUES
  // pilotDetected, blinkRate, eyeAspectRatio and fatigueLevel
  // now come from the AI monitor (Member 4).
  // heartRate and the strap status come from the Garmin HR strap over
  // Bluetooth (heartMonitor).
  // ======================================
 
  bool pilotDetected = false;
  bool autopilotEnabled = false;
 
  int blinkRate = 0;
 
  double eyeAspectRatio = 0.0;
 
  FatigueLevel fatigueLevel = FatigueLevel.normal;
 
  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    monitor.addListener(_onMonitorUpdate);

    heartMonitor.addListener(_onHeartMonitorUpdate);
    heartMonitor.start();
 
    startCamera();

    _backendTimer = Timer.periodic(kBackendInterval, (_) => _syncBackend());
 
    alertPlayer.setReleaseMode(ReleaseMode.loop);
  }
 
  // ======================================
  // AI MONITOR UPDATES
  // ======================================

  void _onMonitorUpdate() {
    if (!mounted) return;

    final changed = pilotDetected != monitor.pilotDetected ||
        fatigueLevel != monitor.fatigueLevel;

    setState(() {
      pilotDetected = monitor.pilotDetected;
      blinkRate = monitor.blinkRate;
      eyeAspectRatio = monitor.eyeAspectRatio;
      fatigueLevel = monitor.fatigueLevel;
    });

    if (changed) {
      updateAlertSound();
    }

    _checkFatigueEvent();
  }

  // ======================================
  // FATIGUE EVENTS
  // One event each time the level rises (normal -> warning, warning -> high,
  // ...). The episode ends after kEpisodeResetAfter back at normal, so a
  // level flickering on and off is not counted twice.
  // ======================================

  void _checkFatigueEvent() {
    final drive = _drive;
    if (drive == null || !pilotDetected || autopilotEnabled) return;
    final now = DateTime.now();

    if (fatigueLevel == FatigueLevel.normal) {
      _normalSince ??= now;
      if (now.difference(_normalSince!) >= kEpisodeResetAfter) {
        _episodeLevel = FatigueLevel.normal;
      }
      return;
    }

    _normalSince = null;
    if (fatigueLevel.index <= _episodeLevel.index) return;
    _episodeLevel = fatigueLevel;

    if (_pendingEvents.length >= kMaxPendingEvents) _pendingEvents.removeAt(0);
    _pendingEvents.add(_PendingEvent(
      drive: drive,
      level: fatigueLevel,
      occurredAt: now,
      heartRateBpm: heartMonitor.heartRate,
      blinkRatePerMinute: blinkRate,
      ear: eyeAspectRatio,
      closureSeconds: monitor.closureSeconds,
    ));
  }
 
  void _onHeartMonitorUpdate() {
    if (!mounted) return;
    setState(() {});
  }

  // ======================================
  // BACKEND
  // Runs on a timer, separate from the camera, so an unreachable
  // backend never stops fatigue monitoring. Keeps retrying until the
  // backend is up; queued events are sent first.
  // ======================================

  /// Creates the backend session for a drive the first time it is needed.
  Future<String> _registerDrive(_Drive drive) async {
    return drive.id ??= await backendService.createSession(
      pilotId: 'pilot-001',
      notes: 'Created by the Flutter fatigue monitoring app',
      startedAt: drive.startedAt,
    );
  }

  Future<void> _syncBackend() async {
    // Never two syncs at once
    if (_backendBusy) return;
    final drive = _drive;
    final monitoring = drive != null && controller != null;
    if (!monitoring && _pendingEvents.isEmpty) return;
    _backendBusy = true;

    try {
      // 1. Queued fatigue events, oldest first
      while (_pendingEvents.isNotEmpty) {
        final e = _pendingEvents.first;
        try {
          await backendService.sendEvent(
            sessionId: await _registerDrive(e.drive),
            severity: _severityName(e.level),
            fatigueLevel: e.level.name,
            message: 'Fatigue level rose to ${e.level.name.toUpperCase()}',
            occurredAt: e.occurredAt,
            heartRateBpm: e.heartRateBpm?.toDouble(),
            blinkRatePerMinute: e.blinkRatePerMinute.toDouble(),
            ear: e.ear,
            closureSeconds: e.closureSeconds,
          );
        } on BackendRejected catch (err) {
          // Refused for good (e.g. invalid data): drop it, don't block the queue
          debugPrint('Fatigue event dropped: $err');
        }
        _pendingEvents.removeAt(0);
      }

      // 2. The current reading, while monitoring
      if (monitoring) {
        final bpm = heartMonitor.heartRate;
        try {
          await backendService.sendReading(
            sessionId: await _registerDrive(drive),
            heartRateBpm: bpm?.toDouble(),
            blinkRatePerMinute: blinkRate.toDouble(),
            ear: eyeAspectRatio,
            fatigueLevel: fatigueLevel.name,
          );
        } on BackendRejected catch (err) {
          // Session missing or ended on the backend: start a fresh one next time
          if (err.statusCode == 404 || err.statusCode == 409) drive.id = null;
          rethrow;
        }
      }

      if (_backendOnline != true) {
        _backendOnline = true;
        debugPrint('Backend connected (session ${drive?.id})');
      }
    } catch (e) {
      // Log once per outage, not every few seconds
      if (_backendOnline != false) {
        debugPrint('Backend unavailable at ${BackendService.baseUrl}: $e');
      }
      _backendOnline = false;
    } finally {
      _backendBusy = false;
    }
  }


  String _severityName(FatigueLevel level) =>
      level.name[0].toUpperCase() + level.name.substring(1);

  /// Ends the current drive on the backend (best effort, not awaited).
  void _endDrive() {
    final id = _drive?.id;
    _drive = null;
    _episodeLevel = FatigueLevel.normal;
    _normalSince = null;
    if (id == null) return;
    backendService.endSession(id).catchError((Object e) {
      debugPrint('Could not end session $id: $e');
    });
  }

  // ======================================
  // CAMERA
  // ======================================
 
  Future<void> startCamera() async {
    if (cameras.isEmpty) return;
 
    // Use the FRONT camera so it faces the pilot
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
 
    controller = CameraController(
      camera,
      ResolutionPreset.medium, // lighter = faster face detection
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );
 
    final newController = controller!;

    await newController.initialize();

    // App was paused or closed while the camera was starting up
    if (!mounted ||
        controller != newController ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      if (controller == newController) controller = null;
      await newController.dispose();
      return;
    }

    // Start sending camera frames to the AI monitor
    await monitor.start(newController, camera);

    // New drive on the first start, or after a long break
    final pausedAt = _pausedAt;
    if (_drive == null ||
        (pausedAt != null &&
            DateTime.now().difference(pausedAt) > kNewDriveAfter)) {
      _endDrive();
      _drive = _Drive(DateTime.now());
    }
    _pausedAt = null;

    if (mounted) {
      setState(() {});
    }
  }

  // Release the camera so it never sends frames to a detached app
  // (this caused a crash when the app was closed).
  Future<void> stopCamera() async {
    final oldController = controller;
    if (oldController == null) return;

    // Remove the preview from the screen before disposing the controller
    setState(() {
      controller = null;
      pilotDetected = false;
      fatigueLevel = FatigueLevel.normal;
    });

    _pausedAt = DateTime.now();
    await alertPlayer.stop();
    await monitor.stop();
    await oldController.dispose();
  }

  // ======================================
  // APP LIFECYCLE (background / foreground)
  // ======================================

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final current = controller;

    if (state == AppLifecycleState.resumed) {
      if (current == null) startCamera();
    } else if (current != null && current.value.isInitialized) {
      // inactive, hidden, paused or detached
      stopCamera();
    }
  }
 
  // ======================================
  // ALERT SOUND
  // ======================================
 
  Future<void> updateAlertSound() async {
    // No pilot = no alarm
    if (!pilotDetected) {
      await alertPlayer.stop();
      return;
    }
 
    // Autopilot = monitoring paused
    if (autopilotEnabled) {
      await alertPlayer.stop();
      return;
    }
 
    switch (fatigueLevel) {
      // =========================
      // NORMAL
      // =========================
 
      case FatigueLevel.normal:
        await alertPlayer.stop();
        break;
 
      // =========================
      // WARNING
      // =========================
 
      case FatigueLevel.warning:
        await alertPlayer.stop();
 
        await alertPlayer.setVolume(0.35);
        await alertPlayer.setPlaybackRate(1.0);
        await alertPlayer.setReleaseMode(ReleaseMode.loop);
 
        await alertPlayer.play(
          AssetSource('sounds/alert.mp3'),
        );
 
        break;
 
      // =========================
      // HIGH FATIGUE
      // =========================
 
      case FatigueLevel.high:
        await alertPlayer.stop();
 
        await alertPlayer.setVolume(0.70);
        await alertPlayer.setPlaybackRate(1.25);
        await alertPlayer.setReleaseMode(ReleaseMode.loop);
 
        await alertPlayer.play(
          AssetSource('sounds/alert.mp3'),
        );
 
        break;
 
      // =========================
      // CRITICAL FATIGUE
      // =========================
 
      case FatigueLevel.critical:
        await alertPlayer.stop();
 
        await alertPlayer.setVolume(1.0);
        await alertPlayer.setPlaybackRate(1.50);
        await alertPlayer.setReleaseMode(ReleaseMode.loop);
 
        await alertPlayer.play(
          AssetSource('sounds/alert.mp3'),
        );
 
        break;
    }
  }
 
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    monitor.removeListener(_onMonitorUpdate);
    monitor.dispose();
    heartMonitor.removeListener(_onHeartMonitorUpdate);
    heartMonitor.dispose();
    _backendTimer?.cancel();
    _endDrive();
 
    controller?.dispose();
    alertPlayer.dispose();
 
    super.dispose();
  }
 
  // ======================================
  // MONITORING STATUS
  // ======================================
 
  String get monitoringStatus {
    if (!pilotDetected) {
      return 'WAITING FOR PILOT';
    }
 
    if (autopilotEnabled) {
      return 'MONITORING PAUSED';
    }
 
    if (monitor.calibrating) {
      return 'CALIBRATING - KEEP EYES OPEN';
    }
 
    return 'MONITORING ACTIVE';
  }
 
  Color get monitoringColor {
    if (!pilotDetected) {
      return Colors.orange;
    }
 
    if (autopilotEnabled) {
      return Colors.blue;
    }
 
    if (monitor.calibrating) {
      return Colors.yellow;
    }
 
    return Colors.greenAccent;
  }
 
  IconData get monitoringIcon {
    if (!pilotDetected) {
      return Icons.person_search;
    }
 
    if (autopilotEnabled) {
      return Icons.pause_circle;
    }
 
    return Icons.sensors;
  }
 
  // ======================================
  // HR STRAP INFORMATION
  // ======================================

  String get heartRateText {
    final bpm = heartMonitor.heartRate;
    return bpm == null ? '-- BPM' : '$bpm BPM';
  }

  String get strapText {
    switch (heartMonitor.status) {
      case StrapStatus.unsupported:
        return 'NO BLUETOOTH';
      case StrapStatus.bluetoothOff:
        return 'BLUETOOTH OFF';
      case StrapStatus.searching:
        return 'SEARCHING';
      case StrapStatus.connecting:
        return 'CONNECTING';
      case StrapStatus.connected:
        return 'CONNECTED';
    }
  }

  // ======================================
  // FATIGUE INFORMATION
  // ======================================
 
  String get fatigueText {
    switch (fatigueLevel) {
      case FatigueLevel.normal:
        return 'NORMAL';
 
      case FatigueLevel.warning:
        return 'WARNING';
 
      case FatigueLevel.high:
        return 'HIGH';
 
      case FatigueLevel.critical:
        return 'CRITICAL';
    }
  }
 
  String get fatigueMessage {
    switch (fatigueLevel) {
      case FatigueLevel.normal:
        return 'Pilot condition normal';
 
      case FatigueLevel.warning:
        return 'FATIGUE WARNING';
 
      case FatigueLevel.high:
        return 'HIGH FATIGUE DETECTED';
 
      case FatigueLevel.critical:
        return 'CRITICAL FATIGUE DETECTED';
    }
  }
 
  Color get fatigueColor {
    switch (fatigueLevel) {
      case FatigueLevel.normal:
        return Colors.greenAccent;
 
      case FatigueLevel.warning:
        return Colors.yellow;
 
      case FatigueLevel.high:
        return Colors.orange;
 
      case FatigueLevel.critical:
        return Colors.red;
    }
  }
 
  IconData get fatigueIcon {
    switch (fatigueLevel) {
      case FatigueLevel.normal:
        return Icons.check_circle;
 
      case FatigueLevel.warning:
        return Icons.warning_amber;
 
      case FatigueLevel.high:
        return Icons.warning;
 
      case FatigueLevel.critical:
        return Icons.emergency;
    }
  }
 
  // ======================================
  // SCREEN
  // ======================================
 
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
 
      body: Stack(
        fit: StackFit.expand,
        children: [
 
          // ==================================
          // FULL SCREEN CAMERA
          // ==================================
 
          if (controller != null &&
              controller!.value.isInitialized)
            Positioned.fill(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: controller!.value.previewSize!.height,
                  height: controller!.value.previewSize!.width,
                  child: CameraPreview(controller!),
                ),
              ),
            )
          else
            const Center(
              child: CircularProgressIndicator(),
            ),
 
          // ==================================
          // CAMERA DARKENING
          // ==================================
 
          Positioned.fill(
            child: Container(
              color: Colors.black.withValues(alpha: 0.12),
            ),
          ),
 
          // ==================================
          // FATIGUE WARNING BORDER
          // ==================================
 
          if (pilotDetected &&
              !autopilotEnabled &&
              fatigueLevel != FatigueLevel.normal)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: fatigueColor,
                      width:
                          fatigueLevel == FatigueLevel.critical
                              ? 8
                              : 4,
                    ),
                  ),
                ),
              ),
            ),
 
          // ==================================
          // MONITORING STATUS
          // ==================================
 
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 15),
                child: HudPanel(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        monitoringIcon,
                        color: monitoringColor,
                        size: 20,
                      ),
 
                      const SizedBox(width: 8),
 
                      Text(
                        monitoringStatus,
                        style: TextStyle(
                          color: monitoringColor,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
 
          // ==================================
          // CENTRE FATIGUE WARNING
          // ==================================
 
          if (pilotDetected &&
              !autopilotEnabled &&
              fatigueLevel != FatigueLevel.normal)
            SafeArea(
              child: Align(
                alignment: Alignment.center,
                child: HudPanel(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        fatigueIcon,
                        color: fatigueColor,
                        size: 45,
                      ),
 
                      const SizedBox(height: 8),
 
                      Text(
                        fatigueMessage,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: fatigueColor,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
 
          // ==================================
          // TOP LEFT - HEART RATE
          // ==================================
 
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.only(
                  top: 80,
                  left: 20,
                ),
                child: HudMetric(
                  icon: Icons.favorite,
                  label: 'HEART RATE',
                  value: heartRateText,
                ),
              ),
            ),
          ),
 
          // ==================================
          // TOP RIGHT - BLINK RATE
          // ==================================
 
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(
                  top: 80,
                  right: 20,
                ),
                child: HudMetric(
                  icon: Icons.remove_red_eye,
                  label: 'BLINK RATE',
                  value: '$blinkRate / MIN',
                  alignRight: true,
                ),
              ),
            ),
          ),
 
          // ==================================
          // LEFT SIDE - EAR
          // ==================================
 
          SafeArea(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(
                  left: 20,
                ),
                child: HudMetric(
                  icon: Icons.visibility,
                  label: 'EYE ASPECT RATIO',
                  value: eyeAspectRatio.toStringAsFixed(2),
                ),
              ),
            ),
          ),
 
          // ==================================
          // BOTTOM LEFT - HR STRAP
          // ==================================
 
          SafeArea(
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.only(
                  left: 20,
                  bottom: 100,
                ),
                child: HudMetric(
                  icon: Icons.monitor_heart,
                  label: 'HR STRAP',
                  value: strapText,
                  valueColor: heartMonitor.connected
                      ? Colors.greenAccent
                      : Colors.orange,
                ),
              ),
            ),
          ),
 
          // ==================================
          // BOTTOM RIGHT - FATIGUE RISK
          // ==================================
 
          SafeArea(
            child: Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.only(
                  right: 20,
                  bottom: 100,
                ),
                child: HudMetric(
                  icon: fatigueIcon,
                  label: 'FATIGUE RISK',
                  value: fatigueText,
                  valueColor: fatigueColor,
                  alignRight: true,
                ),
              ),
            ),
          ),
 
          // ==================================
          // BOTTOM CONTROLS (AUTOPILOT ONLY)
          // The Pilot switch and fatigue dropdown were removed:
          // those values now come from the AI monitor.
          // ==================================
 
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(
                  left: 15,
                  right: 15,
                  bottom: 15,
                ),
                child: HudPanel(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
 
                      // AUTOPILOT
 
                      const Icon(
                        Icons.flight,
                        size: 18,
                      ),
 
                      const SizedBox(width: 4),
 
                      const Text('Autopilot'),
 
                      Switch(
                        value: autopilotEnabled,
                        onChanged: (value) async {
                          setState(() {
                            autopilotEnabled = value;
                          });
 
                          await updateAlertSound();
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
 
// ======================================
// TRANSPARENT HUD PANEL
// ======================================
 
class HudPanel extends StatelessWidget {
  final Widget child;
 
  const HudPanel({
    super.key,
    required this.child,
  });
 
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: 8,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.15),
        ),
      ),
      child: child,
    );
  }
}
 
// ======================================
// HUD METRIC
// ======================================
 
class HudMetric extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool alignRight;
  final Color? valueColor;
 
  const HudMetric({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.alignRight = false,
    this.valueColor,
  });
 
  @override
  Widget build(BuildContext context) {
    return HudPanel(
      child: Column(
        crossAxisAlignment:
            alignRight
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 17,
                color: Colors.white70,
              ),
 
              const SizedBox(width: 6),
 
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
 
          const SizedBox(height: 3),
 
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}