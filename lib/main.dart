import 'dart:async';
import 'dart:io';
 
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';

import 'ai/fatigue_monitor.dart'; // Member 4: AI & computer vision
import 'alerts/alert_player.dart'; // beeps + alarm
import 'alerts/limit_advisor.dart'; // break / high-risk period warnings
import 'sensors/heart_rate_monitor.dart'; // Garmin HR strap (Bluetooth)
import 'services/backend_service.dart'; // REST backend
import 'sim/fatigue_simulator.dart'; // menu simulations

late List<CameraDescription> cameras;

// A pause longer than this (app in the background) starts a new drive.
const Duration kNewDriveAfter = Duration(minutes: 5);
// A fatigue episode ends after this long back at normal.
const Duration kEpisodeResetAfter = Duration(seconds: 10);
// Events kept while the backend is unreachable.
const int kMaxPendingEvents = 200;
// How often to check the driving limits, refresh them, and show advisories.
const Duration kLimitsCheckEvery = Duration(seconds: 30);
const Duration kLimitsRefresh = Duration(minutes: 15);
const Duration kAdvisoryShowFor = Duration(seconds: 30);

// Backend-limit simulations: a virtual clock running this many times faster
// than real time, for this long.
const int kLimitSimSpeed = 30;
const Duration kLimitSimLength = Duration(seconds: 30);

/// Options in the top-right menu.
enum _MenuAction { warning, high, critical, fullCycle, breakLimit, riskPeriod, stop }

/// Fast-forwarded virtual clock used to simulate the backend's limits.
class _LimitSim {
  final String name;
  final DrivingLimits limits; // only the limit being simulated
  final DateTime driveStart; // virtual
  final DateTime virtualAnchor;
  final DateTime realAnchor = DateTime.now();
  final LimitAdvisor advisor = LimitAdvisor();

  _LimitSim(this.name, this.limits, this.driveStart, this.virtualAnchor);

  DateTime get now =>
      virtualAnchor.add(DateTime.now().difference(realAnchor) * kLimitSimSpeed);
}

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
 
  // Fatigue alarms (beeps / continuous) and advisory beeps
  final AlertPlayer alerts = AlertPlayer();

  // Driving limits from the backend (break interval, high-risk periods)
  final LimitAdvisor _advisor = LimitAdvisor();
  DrivingLimits? _limits;
  DateTime? _limitsFetchedAt;
  Timer? _limitsTimer;
  String? _advisory; // advisory banner text (null = hidden)
  Timer? _advisoryTimer;

  // Backend-limit simulation (see _startLimitSim)
  _LimitSim? _limitSim;
  Timer? _limitSimTimer;

  bool get _simulating => monitor.isSimulating || _limitSim != null;

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
    _limitsTimer = Timer.periodic(kLimitsCheckEvery, (_) => _checkLimits());
  }

  // ======================================
  // DRIVING LIMITS (advisories with a single beep)
  // ======================================

  Future<void> _checkLimits() async {
    final drive = _drive;
    if (drive == null || controller == null || autopilotEnabled) return;
    if (_limitSim != null) return;

    // Refresh the limits now and then (they change slowly)
    final fetchedAt = _limitsFetchedAt;
    if (fetchedAt == null ||
        DateTime.now().difference(fetchedAt) > kLimitsRefresh) {
      _limitsFetchedAt = DateTime.now();
      try {
        _limits = await backendService.getLimits();
      } catch (e) {
        _limitsFetchedAt = null; // retry on the next check
        debugPrint('Could not load driving limits: $e');
      }
    }

    final limits = _limits;
    if (limits == null || !mounted || _drive != drive) return;
    for (final a in _advisor.check(limits, drive.startedAt, DateTime.now())) {
      _showAdvisory(a.message);
    }
  }

  void _showAdvisory(String message) {
    setState(() => _advisory = message);
    alerts.advisoryBeep();
    _advisoryTimer?.cancel();
    _advisoryTimer = Timer(kAdvisoryShowFor, () {
      if (mounted) setState(() => _advisory = null);
    });
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
    if (monitor.isSimulating) return; // simulations are not recorded
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
      // Current closure if the eyes are shut now, else the last one
      closureSeconds: monitor.closureSeconds > 0
          ? monitor.closureSeconds
          : monitor.lastClosureSeconds,
    ));
  }
 
  void _onHeartMonitorUpdate() {
    if (!mounted) return;
    // Heart rate is one of the fatigue signals
    monitor.heartRateBpm = heartMonitor.heartRate;
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
    // Readings pause while simulating, so test runs don't reach the dashboard
    final monitoring =
        drive != null && controller != null && !monitor.isSimulating;
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
            fatigueScore: monitor.fatigueScore,
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


  // ======================================
  // SIMULATIONS (top-right menu)
  // ======================================

  void _onMenu(_MenuAction action) {
    switch (action) {
      case _MenuAction.warning:
        _startFatigueSim(SimScenario.warning);
      case _MenuAction.high:
        _startFatigueSim(SimScenario.high);
      case _MenuAction.critical:
        _startFatigueSim(SimScenario.critical);
      case _MenuAction.fullCycle:
        _startFatigueSim(SimScenario.fullCycle);
      case _MenuAction.breakLimit:
        _startLimitSim(riskPeriod: false);
      case _MenuAction.riskPeriod:
        _startLimitSim(riskPeriod: true);
      case _MenuAction.stop:
        _stopLimitSim();
        monitor.stopSimulation();
    }
  }

  void _startFatigueSim(SimScenario scenario) {
    _stopLimitSim();
    monitor.startSimulation(scenario);
  }

  /// Runs a virtual clock up to the backend's break time or riskiest
  /// period, starting 12 virtual minutes before it, so the "in 10 min" and
  /// "now" advisories appear within about 25 s. Uses limits from real and
  /// demo drives; falls back to the built-in demo limits if the backend
  /// can't provide them.
  Future<void> _startLimitSim({required bool riskPeriod}) async {
    monitor.stopSimulation();
    _stopLimitSim();

    DrivingLimits? limits;
    try {
      limits = await backendService.getLimits(includeDemo: true);
    } catch (e) {
      debugPrint('Could not load driving limits: $e');
    }
    if (!mounted) return;
    final missing = limits == null ||
        (riskPeriod ? limits.zones.isEmpty : limits.breakEveryMinutes == null);
    if (missing) {
      limits = DrivingLimits.demo;
      _toast('Backend limits not available: using the demo-data limits.');
    }

    final now = DateTime.now().toUtc();
    _LimitSim sim;
    if (!riskPeriod) {
      final every = limits.breakEveryMinutes!;
      sim = _LimitSim(
        'Break reminder',
        DrivingLimits(
            breakEveryMinutes: every,
            utcOffsetMinutes: limits.utcOffsetMinutes,
            zones: const []),
        now.subtract(Duration(minutes: every - 12)),
        now,
      );
    } else {
      final zone = limits.zones.first; // the riskiest
      // Virtual time: 2 minutes past the zone's hour (backend time zone),
      // 12 minutes of driving before the zone starts.
      final offset = Duration(minutes: limits.utcOffsetMinutes);
      final local = now.add(offset);
      final anchor =
          DateTime.utc(local.year, local.month, local.day, zone.hour, 2)
              .subtract(offset);
      final driven = zone.driveStartMin > 12 ? zone.driveStartMin - 12 : 0;
      sim = _LimitSim(
        'High-risk period',
        DrivingLimits(
            breakEveryMinutes: null,
            utcOffsetMinutes: limits.utcOffsetMinutes,
            zones: [zone]),
        anchor.subtract(Duration(minutes: driven)),
        anchor,
      );
    }

    setState(() => _limitSim = sim);
    _limitSimTimer =
        Timer.periodic(const Duration(milliseconds: 500), (_) => _tickLimitSim());
  }

  void _tickLimitSim() {
    final sim = _limitSim;
    if (sim == null || !mounted) return;
    if (DateTime.now().difference(sim.realAnchor) > kLimitSimLength) {
      _stopLimitSim();
      return;
    }
    for (final a in sim.advisor.check(sim.limits, sim.driveStart, sim.now)) {
      _showAdvisory(a.message);
    }
    setState(() {}); // virtual clock in the status bar
  }

  void _stopLimitSim() {
    _limitSimTimer?.cancel();
    _limitSimTimer = null;
    if (_limitSim != null && mounted) setState(() => _limitSim = null);
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
      monitor.resetFatigue();
      _advisor.reset();
      _limitsFetchedAt = null; // fetch fresh limits for the new drive
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
    await alerts.setLevel(FatigueLevel.normal);
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
 
  /// WARNING: 3 beeps every minute, HIGH: 5 beeps every minute,
  /// CRITICAL: continuous alarm (see alerts/alert_player.dart).
  Future<void> updateAlertSound() async {
    // No alarm without a pilot in view, or while on autopilot
    final allowed = pilotDetected && !autopilotEnabled;
    await alerts.setLevel(allowed ? fatigueLevel : FatigueLevel.normal);
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
    alerts.dispose();
    _limitsTimer?.cancel();
    _advisoryTimer?.cancel();
    _limitSimTimer?.cancel();

    super.dispose();
  }
 
  // ======================================
  // MONITORING STATUS
  // ======================================
 
  String get monitoringStatus {
    if (monitor.isSimulating) {
      final left = monitor.simulationSecondsLeft;
      return 'SIMULATION: ${monitor.simulationPhase.toUpperCase()}'
          '${left == null ? '' : ' · ${left}s'}';
    }

    final limitSim = _limitSim;
    if (limitSim != null) {
      final now = limitSim.now;
      final driven = now.difference(limitSim.driveStart).inMinutes;
      final local = now.toUtc().add(
          Duration(minutes: limitSim.limits.utcOffsetMinutes));
      String two(int n) => n.toString().padLeft(2, '0');
      return 'SIMULATION: ${limitSim.name.toUpperCase()} · '
          '${driven ~/ 60}H${two(driven % 60)} DRIVING · '
          '${two(local.hour)}:${two(local.minute)}';
    }

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
    if (_simulating) {
      return Colors.purpleAccent;
    }

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
    if (_simulating) {
      return Icons.science;
    }

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
        return 'PULL OVER TO REST';

      case FatigueLevel.high:
        return 'PULL OVER IMMEDIATELY';

      case FatigueLevel.critical:
        return 'STOP FOR REST IMMEDIATELY';
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
                // Side padding keeps clear of the menu button (top right)
                padding: const EdgeInsets.only(top: 15, left: 56, right: 56),
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

                      Flexible(
                        child: Text(
                          monitoringStatus,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: monitoringColor,
                            fontSize: _simulating ? 13 : 16,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
 
          // ==================================
          // DRIVING-LIMIT ADVISORY (break due / high-risk period)
          // ==================================

          if (_advisory != null && !autopilotEnabled)
            SafeArea(
              child: Align(
                alignment: const Alignment(0, 0.35),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: HudPanel(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.schedule,
                            color: Colors.lightBlueAccent,
                            size: 22,
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              _advisory!,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
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

                      // Main cause, e.g. "frequent yawning"
                      if (monitor.fatigueReason.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            monitor.fatigueReason.toUpperCase(),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              letterSpacing: 1,
                            ),
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
                  // Level plus the 0-100 score that builds up over time
                  value: '$fatigueText ${monitor.fatigueScore.round()}',
                  valueColor: fatigueColor,
                  alignRight: true,
                ),
              ),
            ),
          ),
 
          // ==================================
          // TOP RIGHT - SIMULATIONS MENU
          // ==================================

          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 6, right: 6),
                child: PopupMenuButton<_MenuAction>(
                  icon: const Icon(Icons.menu, color: Colors.white),
                  tooltip: 'Simulations',
                  color: const Color(0xFF1E1E1E),
                  onSelected: _onMenu,
                  itemBuilder: (_) {
                    final active = monitor.simulationScenario;
                    PopupMenuItem<_MenuAction> item(
                      _MenuAction action,
                      String label,
                      IconData icon, {
                      bool selected = false,
                    }) =>
                        PopupMenuItem(
                          value: action,
                          child: Row(
                            children: [
                              Icon(
                                selected ? Icons.check : icon,
                                size: 20,
                                color: selected
                                    ? Colors.purpleAccent
                                    : Colors.white70,
                              ),
                              const SizedBox(width: 12),
                              Text(label),
                            ],
                          ),
                        );
                    PopupMenuItem<_MenuAction> header(String text) =>
                        PopupMenuItem(
                          enabled: false,
                          height: 32,
                          child: Text(
                            text,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1,
                            ),
                          ),
                        );
                    return [
                      header('SIMULATE FATIGUE'),
                      item(_MenuAction.warning, SimScenario.warning.label,
                          Icons.warning_amber,
                          selected: active == SimScenario.warning),
                      item(_MenuAction.high, SimScenario.high.label,
                          Icons.warning,
                          selected: active == SimScenario.high),
                      item(_MenuAction.critical, SimScenario.critical.label,
                          Icons.emergency,
                          selected: active == SimScenario.critical),
                      item(_MenuAction.fullCycle, SimScenario.fullCycle.label,
                          Icons.loop,
                          selected: active == SimScenario.fullCycle),
                      const PopupMenuDivider(),
                      header('SIMULATE BACKEND LIMITS'),
                      item(_MenuAction.breakLimit, 'Break reminder',
                          Icons.free_breakfast,
                          selected: _limitSim?.name == 'Break reminder'),
                      item(_MenuAction.riskPeriod, 'High-risk period',
                          Icons.schedule,
                          selected: _limitSim?.name == 'High-risk period'),
                      if (_simulating) ...[
                        const PopupMenuDivider(),
                        item(_MenuAction.stop, 'Stop simulation',
                            Icons.stop_circle),
                      ],
                    ];
                  },
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