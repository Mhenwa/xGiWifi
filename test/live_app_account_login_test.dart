import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:xgiwifi/giwifi/app_network_identity.dart';
import 'package:xgiwifi/giwifi/giwifi_client.dart';
import 'package:xgiwifi/giwifi/giwifi_models.dart';

void main() {
  final liveEnabled = Platform.environment['XGIWIFI_LIVE_ACCOUNT_LOGIN'] == '1';
  final requestedProfile =
      Platform.environment['XGIWIFI_LIVE_PROFILE']?.trim().toLowerCase() ??
      'apad';
  final profile = switch (requestedProfile) {
    'android' => DeviceProfile.android,
    'apad' => DeviceProfile.apad,
    _ => throw ArgumentError.value(
      requestedProfile,
      'XGIWIFI_LIVE_PROFILE',
      'Use android or apad',
    ),
  };

  test(
    'live ${profile.label} APK account-layer login',
    () async {
      final settingsPath =
          Platform.environment['XGIWIFI_SETTINGS_PATH'] ??
          '/home/mhenwa/.local/share/xgiwifi/shared_preferences.json';
      final settings = Map<String, dynamic>.from(
        jsonDecode(await File(settingsPath).readAsString()) as Map,
      );
      final username = settings['flutter.saved_account']?.toString() ?? '';
      final password = settings['flutter.saved_password']?.toString() ?? '';
      final baseUrl =
          settings['flutter.base_url']?.toString() ?? 'http://10.100.100.2';
      final expectedInterface =
          Platform.environment['XGIWIFI_EXPECTED_INTERFACE'] ?? 'enp9s0';
      final serviceTypes =
          (Platform.environment['XGIWIFI_SERVICE_TYPES'] ?? '2')
              .split(',')
              .map((String value) => int.tryParse(value.trim()))
              .whereType<int>()
              .toList(growable: false);
      final portalUri = _originUri(Uri.parse(baseUrl));
      final identity = await resolveAppNetworkIdentity(portalUri);
      final gatewayIp =
          Platform.environment['XGIWIFI_GATEWAY_IP'] ?? '10.20.1.1';
      final accountApi = Uri(
        scheme: 'http',
        host: portalUri.host,
        port: 8080,
        path: '/wocloud_v2/appUser/appLogin.bin',
      );

      expect(username, isNotEmpty);
      expect(password, isNotEmpty);
      expect(serviceTypes, isNotEmpty);
      expect(identity.interfaceName, expectedInterface);
      // ignore: avoid_print
      print(
        'LIVE_ACCOUNT profile=${profile.label} endpoint=${accountApi.origin} '
        'interface=${identity.interfaceName} userIp=${identity.userIp} '
        'userMac=${identity.userMac}',
      );

      final client = http.Client();
      try {
        for (final serviceType in serviceTypes) {
          final inner = <String, Object>{
            'service_type': _encryptField('$serviceType'),
            'phone': _encryptField(username),
            'staticPassword': _encryptField(password),
            'ip': _encryptField(identity.userIp),
            'apMac': '',
            'gwAddress': _encryptField(gatewayIp),
            'staType': _encryptField(profile.staType),
            'staModel': _encryptField(profile.staModel),
          };
          final outer = <String, Object>{
            'token': _encryptField(''),
            'version': '2.4.1.21',
            'mac': _encryptField(identity.userMac),
            'gatewayId': _encryptField(''),
            'data': jsonEncode(inner),
          };
          final response = await client.post(
            accountApi,
            headers: const <String, String>{
              'Content-Type': 'text/plain;charset=utf-8',
            },
            body: jsonEncode(outer),
          );
          expect(response.statusCode, 200);
          final result = _AccountLoginResponse.fromBody(response.body);
          // ignore: avoid_print
          print(
            'LIVE_ACCOUNT RESULT profile=${profile.label} '
            'serviceType=$serviceType resultCode=${result.resultCode} '
            'resultMsg=${result.resultMsg} dataKeys=${result.dataKeys.join(',')}',
          );
          if (serviceType != serviceTypes.last) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
        }
      } finally {
        client.close();
      }
    },
    skip: liveEnabled
        ? false
        : 'Set XGIWIFI_LIVE_ACCOUNT_LOGIN=1 to run on GiWiFi',
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

String _encryptField(String value) => encryptAppPortalPayload(value);

Uri _originUri(Uri value) {
  return Uri(
    scheme: value.scheme,
    host: value.host,
    port: value.hasPort ? value.port : null,
  );
}

class _AccountLoginResponse {
  const _AccountLoginResponse({
    required this.resultCode,
    required this.resultMsg,
    required this.dataKeys,
  });

  final int? resultCode;
  final String resultMsg;
  final List<String> dataKeys;

  factory _AccountLoginResponse.fromBody(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('Account login response is not an object');
    }
    final response = Map<String, dynamic>.from(decoded);
    final rawData = response['data'];
    Map<String, dynamic>? data;
    if (rawData is Map) {
      data = Map<String, dynamic>.from(rawData);
    } else if (rawData is String && rawData.trim().startsWith('{')) {
      final decodedData = jsonDecode(rawData);
      if (decodedData is Map) {
        data = Map<String, dynamic>.from(decodedData);
      }
    }
    final keys = data?.keys.toList(growable: false) ?? const <String>[];
    return _AccountLoginResponse(
      resultCode: int.tryParse('${response['resultCode']}'),
      resultMsg: response['resultMsg']?.toString() ?? '',
      dataKeys: keys,
    );
  }
}
