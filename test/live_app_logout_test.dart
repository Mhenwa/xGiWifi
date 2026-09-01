import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:xgiwifi/giwifi/app_network_identity.dart';
import 'package:xgiwifi/giwifi/giwifi_client.dart';

void main() {
  final liveEnabled = Platform.environment['XGIWIFI_LIVE_LOGOUT'] == '1';

  test(
    'live App Portal logout restores authState 1 on RJ45',
    () async {
      final settingsPath =
          Platform.environment['XGIWIFI_SETTINGS_PATH'] ??
          '/home/mhenwa/.local/share/xgiwifi/shared_preferences.json';
      final settings = Map<String, dynamic>.from(
        jsonDecode(await File(settingsPath).readAsString()) as Map,
      );
      final username = settings['flutter.saved_account']?.toString() ?? '';
      final baseUrl =
          settings['flutter.base_url']?.toString() ?? 'http://10.100.100.2';
      final expectedInterface =
          Platform.environment['XGIWIFI_EXPECTED_INTERFACE'] ?? 'enp9s0';
      final portalUri = _originUri(Uri.parse(baseUrl));
      final identity = await resolveAppNetworkIdentity(portalUri);

      expect(username, isNotEmpty);
      expect(identity.interfaceName, expectedInterface);
      // ignore: avoid_print
      print(
        'LIVE_LOGOUT IDENTITY interface=${identity.interfaceName} '
        'userIp=${identity.userIp} userMac=${identity.userMac}',
      );

      final client = http.Client();
      try {
        final before = await _queryState(
          client: client,
          portalUri: portalUri,
          userIp: identity.userIp,
          username: username,
        );
        // ignore: avoid_print
        print(
          'LIVE_LOGOUT BEFORE resultCode=${before.resultCode} '
          'authState=${before.authState}',
        );

        final logout = await _postSigned(
          client: client,
          portalUri: portalUri,
          path: '/gportal/app/authLogout',
          fields: <String, String>{
            'timestamp': _epochSeconds(),
            'userIp': identity.userIp,
            'userName': username,
          },
        );
        // ignore: avoid_print
        print(
          'LIVE_LOGOUT RESPONSE resultCode=${logout.resultCode} '
          'info=${logout.info}',
        );
        expect(logout.resultCode, 0, reason: logout.info);

        _DecodedAppResponse? state;
        for (var attempt = 1; attempt <= 12; attempt++) {
          state = await _queryState(
            client: client,
            portalUri: portalUri,
            userIp: identity.userIp,
            username: username,
          );
          // ignore: avoid_print
          print(
            'LIVE_LOGOUT POLL attempt=$attempt '
            'resultCode=${state.resultCode} authState=${state.authState}',
          );
          if (state.resultCode == 0 && state.authState == 1) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 750));
        }

        expect(state?.resultCode, 0);
        expect(
          state?.authState,
          1,
          reason:
              'Portal authentication state did not return to unauthenticated',
        );
      } finally {
        client.close();
      }
    },
    skip: liveEnabled ? false : 'Set XGIWIFI_LIVE_LOGOUT=1 to run on GiWiFi',
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

Future<_DecodedAppResponse> _queryState({
  required http.Client client,
  required Uri portalUri,
  required String userIp,
  required String username,
}) {
  return _postSigned(
    client: client,
    portalUri: portalUri,
    path: '/gportal/app/queryAuthState',
    fields: <String, String>{
      'timestamp': _epochSeconds(),
      'userIp': userIp,
      'userName': username,
    },
    contentTypeWithCharset: true,
  );
}

Future<_DecodedAppResponse> _postSigned({
  required http.Client client,
  required Uri portalUri,
  required String path,
  required Map<String, String> fields,
  bool contentTypeWithCharset = false,
}) async {
  final plaintext = buildAppPortalSignedPayload(fields);
  final response = await client.post(
    portalUri.resolve(path),
    headers: <String, String>{
      'Content-Type': contentTypeWithCharset
          ? 'application/x-www-form-urlencoded; charset=UTF-8'
          : 'application/x-www-form-urlencoded',
      'User-Agent': 'okhttp/3.8.0',
    },
    body: <String, String>{'data': encodeAppPortalData(plaintext)},
  );
  expect(response.statusCode, 200, reason: 'HTTP failure for $path');
  return _DecodedAppResponse.fromBody(response.body);
}

Uri _originUri(Uri value) {
  return Uri(
    scheme: value.scheme,
    host: value.host,
    port: value.hasPort ? value.port : null,
  );
}

String _epochSeconds() =>
    (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();

class _DecodedAppResponse {
  const _DecodedAppResponse({
    required this.resultCode,
    required this.info,
    required this.data,
  });

  final int? resultCode;
  final String info;
  final Map<String, dynamic> data;

  int? get authState => int.tryParse('${data['authState']}');

  factory _DecodedAppResponse.fromBody(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('App Portal response is not a JSON object');
    }
    final outer = Map<String, dynamic>.from(decoded);
    final outerData = outer['data'];
    late final Map<String, dynamic> inner;
    if (_hasResultCode(outer)) {
      inner = outer;
    } else if (outerData is String && outerData.isNotEmpty) {
      final decrypted = jsonDecode(decryptAppPortalData(outerData));
      if (decrypted is! Map) {
        throw const FormatException('Decrypted App Portal data is invalid');
      }
      inner = Map<String, dynamic>.from(decrypted);
    } else if (outerData is Map) {
      inner = Map<String, dynamic>.from(outerData);
    } else {
      throw const FormatException('App Portal response has no data');
    }

    final rawData = inner['data'] ?? inner['resultData'];
    return _DecodedAppResponse(
      resultCode: int.tryParse(
        '${inner['resultCode'] ?? inner['errcode'] ?? inner['errorCode']}',
      ),
      info:
          inner['resultMsg']?.toString() ??
          inner['errmsg']?.toString() ??
          outer['info']?.toString() ??
          '',
      data: _decodeDataMap(rawData),
    );
  }
}

bool _hasResultCode(Map<String, dynamic> value) {
  return value.containsKey('resultCode') ||
      value.containsKey('errcode') ||
      value.containsKey('errorCode');
}

Map<String, dynamic> _decodeDataMap(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  if (value is String && value.trim().isNotEmpty) {
    final decoded = jsonDecode(value);
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
  }
  return <String, dynamic>{};
}
