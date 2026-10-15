// Smoke test for the HUD widgets.
//
// PilotFatigueApp itself needs real cameras (availableCameras() runs in
// main), so this only tests the camera-free HUD building blocks.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pilot_fatigue_app/main.dart';

void main() {
  testWidgets('HudMetric shows its label and value', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: HudMetric(
            icon: Icons.favorite,
            label: 'HEART RATE',
            value: '76 BPM',
          ),
        ),
      ),
    );

    expect(find.text('HEART RATE'), findsOneWidget);
    expect(find.text('76 BPM'), findsOneWidget);
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(find.byType(HudPanel), findsOneWidget);
  });
}
