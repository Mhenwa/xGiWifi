import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'app/app_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settingsStore = AppSettingsStore();
  final initialSettings = await settingsStore.load();

  runApp(
    XGiWifiApp(initialSettings: initialSettings, settingsStore: settingsStore),
  );
}
