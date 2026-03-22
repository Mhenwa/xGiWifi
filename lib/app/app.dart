import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'home_page.dart';

class XGiWifiApp extends StatefulWidget {
  const XGiWifiApp({
    super.key,
    required this.initialSettings,
    required this.settingsStore,
  });

  final AppSettings initialSettings;
  final AppSettingsStore settingsStore;

  @override
  State<XGiWifiApp> createState() => _XGiWifiAppState();
}

class _XGiWifiAppState extends State<XGiWifiApp> {
  static const List<String> _windowsFontFallback = <String>[
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'Segoe UI',
  ];

  late AppSettings _settings;

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
  }

  Future<void> _updateSettings(AppSettings newSettings) async {
    setState(() {
      _settings = newSettings;
    });
    await widget.settingsStore.save(newSettings);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'xGiWifi',
      debugShowCheckedModeBanner: false,
      themeMode: _settings.themeMode,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: HomePage(settings: _settings, onSettingsChanged: _updateSettings),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF2B68FF),
      brightness: brightness,
    );
    final baseTheme = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
    );
    final textTheme = switch (defaultTargetPlatform) {
      TargetPlatform.windows => baseTheme.textTheme.apply(
        fontFamilyFallback: _windowsFontFallback,
      ),
      _ => baseTheme.textTheme,
    };

    return baseTheme.copyWith(
      textTheme: textTheme,
      scaffoldBackgroundColor: brightness == Brightness.light
          ? const Color(0xFFEAF2FF)
          : const Color(0xFF0F1726),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: colorScheme.onSurface,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
      cardTheme: CardThemeData(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: brightness == Brightness.light
            ? Colors.white.withValues(alpha: 0.88)
            : const Color(0xFF162033).withValues(alpha: 0.96),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: BorderSide(
            color: brightness == Brightness.light
                ? const Color(0xFFD7E0F2)
                : const Color(0xFF23314F),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: brightness == Brightness.light
            ? const Color(0xFFF5F8FF)
            : const Color(0xFF101827),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(
            color: brightness == Brightness.light
                ? const Color(0xFFD3DDF0)
                : const Color(0xFF273552),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(
            color: brightness == Brightness.light
                ? const Color(0xFFD3DDF0)
                : const Color(0xFF273552),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 18,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }
}
