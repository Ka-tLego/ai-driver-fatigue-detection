
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../alerts/limit_advisor.dart';

// How often the app sends a reading (backend allows 300 requests/min).
const Duration kBackendInterval = Duration(seconds: 2);

/// The backend received the request but refused it (4xx), so retrying the
/// same request won't help.
class BackendRejected implements Exception {
  final int statusCode;
  final String message;
  BackendRejected(this.statusCode, this.message);

  @override
  String toString() => 'BackendRejected($statusCode): $message';
}

void _check(http.Response response, int expected, String fallback) {
  final data = jsonDecode(response.body);
  if (response.statusCode == expected && data['success'] == true) return;
  final message = (data['message'] ?? fallback).toString();
  final code = response.statusCode;
  if (code >= 400 && code < 500 && code != 429) {
    throw BackendRejected(code, message);
  }
  throw Exception(message);
}

class BackendService {
  // Backend address. Defaults to the hosted backend on Render, so a plain
  // `flutter run` / VS Code Run works. To test against a backend on your PC:
  //   - USB phone:  adb reverse tcp:3000 tcp:3000, then
  //                 flutter run --dart-define=BACKEND_URL=http://localhost:3000/api
  //   - Wi-Fi:      flutter run --dart-define=BACKEND_URL=http://<PC IP>:3000/api
  //   - Emulator:   flutter run --dart-define=BACKEND_URL=http://10.0.2.2:3000/api
  static const String baseUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: 'https://ai-driver-fatigue-detection.onrender.com/api',
  );

  /// Checks whether the backend is reachable.
  Future<bool> checkHealth() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['success'] == true;
      }

      return false;
    } catch (e) {
      return false;
    }
  }

  /// Creates a monitoring session and returns its ID.
  Future<String> createSession({
    String pilotId = 'pilot-001',
    String notes = '',
    DateTime? startedAt,
  }) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/sessions'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'pilotId': pilotId,
            'notes': notes,
            'startedAt': ?startedAt?.toUtc().toIso8601String(),
          }),
        )
        .timeout(const Duration(seconds: 10));

    _check(response, 201, 'Could not create monitoring session.');
    return jsonDecode(response.body)['data']['_id'].toString();
  }

  /// Driving limits learned from past drives (break interval, high-risk
  /// periods). Public endpoint, no password needed. [includeDemo] also
  /// uses the demo drives (for simulations).
  Future<DrivingLimits> getLimits({bool includeDemo = false}) async {
    final query = includeDemo ? '?includeDemo=true' : '';
    final response = await http
        .get(Uri.parse('$baseUrl/limits$query'))
        .timeout(const Duration(seconds: 15));
    _check(response, 200, 'Could not load driving limits.');
    return DrivingLimits.fromJson(
        jsonDecode(response.body)['data'] as Map<String, dynamic>);
  }

  /// Marks a monitoring session as ended.
  Future<void> endSession(String sessionId) async {
    final response = await http
        .patch(
          Uri.parse('$baseUrl/sessions/$sessionId'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'status': 'ended'}),
        )
        .timeout(const Duration(seconds: 10));
    _check(response, 200, 'Could not end monitoring session.');
  }

  /// Records a fatigue event (the level rose to warning, high or critical).
  Future<void> sendEvent({
    required String sessionId,
    required String severity, // Warning / High / Critical
    required String fatigueLevel, // warning / high / critical
    required String message,
    required DateTime occurredAt,
    double? heartRateBpm,
    double? blinkRatePerMinute,
    double? ear,
    double? closureSeconds,
  }) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/events'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'sessionId': sessionId,
            'severity': severity,
            'fatigueLevel': fatigueLevel,
            'message': message,
            'occurredAt': occurredAt.toUtc().toIso8601String(),
            'heartRateBpm': ?heartRateBpm,
            'blinkRatePerMinute': ?blinkRatePerMinute,
            'ear': ?ear,
            'closureSeconds': ?closureSeconds,
          }),
        )
        .timeout(const Duration(seconds: 10));
    _check(response, 201, 'Could not save fatigue event.');
  }

  /// Sends a sensor reading to an existing monitoring session.
  Future<void> sendReading({
    required String sessionId,
    double? heartRateBpm,
    double? blinkRatePerMinute,
    double? ear,
    String? fatigueLevel,
    double? fatigueScore,
  }) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/sessions/$sessionId/readings'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'heartRateBpm': ?heartRateBpm,
            'blinkRatePerMinute': ?blinkRatePerMinute,
            'ear': ?ear,
            'fatigueLevel': ?fatigueLevel,
            'fatigueScore': ?fatigueScore,
            'source': 'flutter_app',
          }),
        )
        .timeout(const Duration(seconds: 10));

    _check(response, 201, 'Could not save sensor reading.');
  }
}
