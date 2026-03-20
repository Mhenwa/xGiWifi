import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xgiwifi/app/app_settings.dart';
import 'package:xgiwifi/app/home_page.dart';

void main() {
  testWidgets('home page renders main sections', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          settings: const AppSettings(),
          onSettingsChanged: (_) async {},
        ),
      ),
    );

    expect(find.text('xGiWifi'), findsOneWidget);
    expect(find.text('账号登录'), findsOneWidget);
    expect(find.text('日志'), findsOneWidget);
  });
}
