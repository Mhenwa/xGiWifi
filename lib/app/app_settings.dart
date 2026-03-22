import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../giwifi/giwifi_models.dart';

const String kDefaultBaseUrl = 'http://10.100.100.2';
const String kPlaceholderGithubUrl = 'https://github.com/Mhenwa/xGiWifi';

class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.baseUrl = kDefaultBaseUrl,
    this.savedAccount = '',
    this.savedPassword = '',
    this.savedProfile = DeviceProfile.windows,
  });

  final ThemeMode themeMode;
  final String baseUrl;
  final String savedAccount;
  final String savedPassword;
  final DeviceProfile savedProfile;

  AppSettings copyWith({
    ThemeMode? themeMode,
    String? baseUrl,
    String? savedAccount,
    String? savedPassword,
    DeviceProfile? savedProfile,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      baseUrl: baseUrl ?? this.baseUrl,
      savedAccount: savedAccount ?? this.savedAccount,
      savedPassword: savedPassword ?? this.savedPassword,
      savedProfile: savedProfile ?? this.savedProfile,
    );
  }
}

class AppSettingsStore {
  static const String _themeModeKey = 'theme_mode';
  static const String _baseUrlKey = 'base_url';
  static const String _savedAccountKey = 'saved_account';
  static const String _savedPasswordKey = 'saved_password';
  static const String _savedProfileKey = 'saved_profile';

  Future<AppSettings> load() async {
    final preferences = await SharedPreferences.getInstance();
    final themeMode = _themeModeFromStorage(
      preferences.getString(_themeModeKey),
    );

    final storedBaseUrl = preferences.getString(_baseUrlKey);
    final baseUrl = storedBaseUrl == null
        ? kDefaultBaseUrl
        : _safeNormalize(storedBaseUrl);

    return AppSettings(
      themeMode: themeMode,
      baseUrl: baseUrl,
      savedAccount: preferences.getString(_savedAccountKey) ?? '',
      savedPassword: preferences.getString(_savedPasswordKey) ?? '',
      savedProfile: _profileFromStorage(
        preferences.getString(_savedProfileKey),
      ),
    );
  }

  Future<void> save(AppSettings settings) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _themeModeKey,
      _themeModeToStorage(settings.themeMode),
    );
    await preferences.setString(
      _baseUrlKey,
      normalizePortalBaseUrl(settings.baseUrl),
    );
    await preferences.setString(_savedAccountKey, settings.savedAccount);
    await preferences.setString(_savedPasswordKey, settings.savedPassword);
    await preferences.setString(
      _savedProfileKey,
      _profileToStorage(settings.savedProfile),
    );
  }

  String _safeNormalize(String value) {
    try {
      return normalizePortalBaseUrl(value);
    } on FormatException {
      return kDefaultBaseUrl;
    }
  }

  ThemeMode _themeModeFromStorage(String? value) {
    return switch (value) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  String _themeModeToStorage(ThemeMode themeMode) {
    return switch (themeMode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
  }

  DeviceProfile _profileFromStorage(String? value) {
    return DeviceProfile.values.where((profile) => profile.name == value).firstOrNull ??
        DeviceProfile.windows;
  }

  String _profileToStorage(DeviceProfile profile) => profile.name;
}

String normalizePortalBaseUrl(String rawValue) {
  final value = rawValue.trim();
  if (value.isEmpty) {
    throw const FormatException('Portal 地址不能为空');
  }

  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw const FormatException('Portal 地址格式不正确');
  }

  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw const FormatException('Portal 地址仅支持 http 或 https');
  }

  return uri.origin;
}

String themeModeLabel(ThemeMode themeMode) {
  return switch (themeMode) {
    ThemeMode.system => '跟随系统',
    ThemeMode.light => '浅色',
    ThemeMode.dark => '深色',
  };
}
