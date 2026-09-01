import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xgiwifi/app/app_settings.dart';
import 'package:xgiwifi/giwifi/giwifi_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettingsStore profile migration', () {
    for (final migration in <(String, DeviceProfile)>[
      ('iphone', DeviceProfile.android),
      ('ipad', DeviceProfile.apad),
      ('android', DeviceProfile.android),
      ('apad', DeviceProfile.apad),
      ('windows', DeviceProfile.windows),
      ('future-profile', DeviceProfile.windows),
    ]) {
      test('${migration.$1} maps to ${migration.$2.name}', () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'saved_profile': migration.$1,
        });

        final settings = await AppSettingsStore().load();
        final preferences = await SharedPreferences.getInstance();

        expect(settings.savedProfile, migration.$2);
        expect(preferences.getString('saved_profile'), migration.$2.name);
      });
    }
  });

  group('AppSettingsStore appUuid', () {
    test('generates, persists, and reuses one appUuid', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = AppSettingsStore();

      final firstLoad = await store.load();
      final secondLoad = await store.load();
      final preferences = await SharedPreferences.getInstance();

      expect(firstLoad.appUuid, hasLength(35));
      expect(isGiWifiAppUuid(firstLoad.appUuid), isTrue);
      expect(secondLoad.appUuid, firstLoad.appUuid);
      expect(preferences.getString('app_uuid'), firstLoad.appUuid);
    });

    test('keeps an existing valid appUuid', () async {
      final existingAppUuid = generateGiWifiAppUuid();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'app_uuid': existingAppUuid,
      });

      final settings = await AppSettingsStore().load();

      expect(settings.appUuid, existingAppUuid);
    });

    test('keeps appUuid stable while saving other settings', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = AppSettingsStore();
      final initialSettings = await store.load();

      await store.save(
        initialSettings.copyWith(
          savedAccount: 'account',
          savedProfile: DeviceProfile.apad,
        ),
      );
      final reloadedSettings = await store.load();

      expect(reloadedSettings.appUuid, initialSettings.appUuid);
      expect(reloadedSettings.savedAccount, 'account');
      expect(reloadedSettings.savedProfile, DeviceProfile.apad);
    });

    test('replaces an invalid stored appUuid', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'app_uuid': 'invalid',
      });

      final settings = await AppSettingsStore().load();

      expect(settings.appUuid, isNot('invalid'));
      expect(isGiWifiAppUuid(settings.appUuid), isTrue);
    });

    test('defaults to an empty value before loading persisted settings', () {
      expect(const AppSettings().appUuid, isEmpty);
    });
  });
}
