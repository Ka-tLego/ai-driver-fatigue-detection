
import 'dart:convert';

import 'package:http/http.dart' as http;

// How often the app sends a reading (backend allows 300 requests/min).
const Duration kBackendInterval = Duration(seconds: 2);

class BackendService {
  // Backend address. "localhost" on a phone means the phone itself, so:
  //   - USB phone:  run `adb reverse tcp:3000 tcp:3000` (keeps this default)
  //   - Wi-Fi:      flutter run --dart-define=BACKEND_URL=http://<PC IP>:3000/api
  //   - Emulator:   flutter run --dart-define=BACKEND_URL=http://10.0.2.2:3000/api
  static const String baseUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: 'http://localhost:3000/api',
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
  }) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/sessions'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'pilotId': pilotId,
            'notes': notes,
          }),
        )
        .timeout(const Duration(seconds: 10));

    final data = jsonDecode(response.body);

    if (response.statusCode != 201 || data['success'] != true) {
      throw Exception(data['message'] ?? 'Could not create monitoring session.');
    }

    return data['data']['_id'].toString();
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

    final data = jsonDecode(response.body);

    if (response.statusCode != 201 || data['success'] != true) {
      throw Exception(data['message'] ?? 'Could not save sensor reading.');
    }
  }
}
