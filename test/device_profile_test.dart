import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xgiwifi/app/app_settings.dart';
import 'package:xgiwifi/app/home_page.dart';
import 'package:xgiwifi/giwifi/giwifi_models.dart';

void main() {
  group('DeviceProfile', () {
    test('exposes the supported profiles in UI order', () {
      expect(DeviceProfile.values, <DeviceProfile>[
        DeviceProfile.android,
        DeviceProfile.apad,
        DeviceProfile.windows,
      ]);
      expect(DeviceProfile.values.map((profile) => profile.label), <String>[
        'Android',
        'APad',
        'Windows',
      ]);
    });

    test('defines Android App Portal fields', () {
      final profile = DeviceProfile.android;

      expect(profile.protocol, DeviceProtocol.appPortal);
      expect(profile.btype, '1');
      expect(profile.staType, 'phone');
      expect(profile.staModel, 'Google,Pixel 9,35,15');
      expect(profile.userAgent, contains('Android 15'));
      expect(profile.userAgent, contains('Pixel 9'));
      expect(profile.loginPath, contains('logintype=1'));
    });

    test('defines APad App Portal fields', () {
      final profile = DeviceProfile.apad;

      expect(profile.protocol, DeviceProtocol.appPortal);
      expect(profile.btype, '2');
      expect(profile.staType, 'pad');
      expect(profile.staModel, 'samsung,SM-T870,34,14');
      expect(profile.userAgent, contains('Android 15'));
      expect(profile.userAgent, contains('Pixel Tablet'));
      expect(profile.loginPath, contains('logintype=1'));
    });

    test('preserves the Windows Web Portal profile', () {
      final profile = DeviceProfile.windows;

      expect(profile.protocol, DeviceProtocol.webPortal);
      expect(
        profile.userAgent,
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/146.0.0.0 Safari/537.36',
      );
      expect(profile.deviceMode, 'Windows NT 10.0');
      expect(profile.deviceType, '1');
      expect(profile.deviceOsType, '3');
      expect(profile.isMobile, '0');
      expect(profile.loginPath, '/gportal/web/login?has_reload=1');
    });
  });

  group('GiWiFi appUuid', () {
    test('is a UUID v4 with the fourth hyphen removed', () {
      final appUuid = generateGiWifiAppUuid();

      expect(appUuid, hasLength(35));
      expect('-'.allMatches(appUuid), hasLength(3));
      expect(isGiWifiAppUuid(appUuid), isTrue);

      final standardUuid =
          '${appUuid.substring(0, 23)}-'
          '${appUuid.substring(23)}';
      expect(
        standardUuid,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-'
            r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    });
  });

  testWidgets('shows all three profiles without narrow-screen overflow', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          settings: AppSettings(appUuid: generateGiWifiAppUuid()),
          onSettingsChanged: (_) async {},
        ),
      ),
    );

    expect(find.text('Android'), findsOneWidget);
    expect(find.text('APad'), findsOneWidget);
    expect(find.text('Windows'), findsOneWidget);
    expect(find.byType(SegmentedButton<DeviceProfile>), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
