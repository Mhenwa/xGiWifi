import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xgiwifi/giwifi/app_network_identity.dart';
import 'package:xgiwifi/giwifi/giwifi_client.dart';
import 'package:xgiwifi/giwifi/giwifi_models.dart';

void main() {
  test(
    'Android account layer matches the APK envelope and runs first',
    () async {
      final requests = <http.Request>[];
      final client = MockClient((http.Request request) async {
        requests.add(request);
        if (request.url.path == '/wocloud_v2/appUser/appLogin.bin') {
          expect(request.url.port, 8080);
          expect(request.headers['content-type'], 'text/plain;charset=utf-8');
          final envelope = _decodeAccountRequest(request);
          expect(envelope.outer['token'], _encrypted('TOKEN-1'));
          expect(envelope.outer['version'], kGiWifiApkVersion);
          expect(envelope.outer['mac'], _encrypted('AA:BB:CC:DD:EE:FF'));
          expect(envelope.outer['gatewayId'], _encrypted('GW-1'));
          expect(envelope.inner, <String, String>{
            'service_type': _encrypted('1'),
            'phone': _encrypted('account'),
            'staticPassword': _encrypted('secret'),
            'ip': _encrypted('10.0.0.42'),
            'apMac': '',
            'gwAddress': _encrypted('10.0.0.1'),
            'staType': _encrypted('phone'),
            'staModel': _encrypted('Google,Pixel 9,35,15'),
          });
          return _jsonResponse(<String, dynamic>{
            'resultCode': 0,
            'resultMsg': '登录成功！',
            'data': '',
          });
        }

        expect(
          request.url.path,
          anyOf('/gportal/app/queryAuthState', '/gportal/app/authLogin'),
        );
        final fields = _decodePortalRequest(request);
        if (request.url.path.endsWith('queryAuthState')) {
          expect(fields['userName'], 'account');
          return _jsonResponse(<String, dynamic>{
            'resultCode': 0,
            'resultMsg': 'state ok',
            'data': <String, dynamic>{'authState': 1},
          });
        }
        expect(fields['btype'], '1');
        expect(fields['staType'], 'phone');
        return _jsonResponse(<String, dynamic>{
          'resultCode': 0,
          'resultMsg': '认证成功！',
          'data': <String, dynamic>{},
        });
      });

      final result =
          await GiWifiClient(
            clientFactory: () => client,
            appPortalProbeUrl: '',
            appNetworkIdentityResolver: (_) async => const AppNetworkIdentity(
              userIp: '10.0.0.42',
              userMac: 'AA:BB:CC:DD:EE:FF',
              gatewayIp: '10.0.0.254',
            ),
          ).login(
            baseUrl: 'http://10.100.100.2',
            profile: DeviceProfile.android,
            username: 'account',
            password: 'secret',
            appUuid: '12345678-1234-1234-123456789abc',
            appAccountOptions: const AppAccountLoginOptions(
              serviceType: 1,
              token: 'TOKEN-1',
              gatewayId: 'GW-1',
              gatewayAddress: '10.0.0.1',
            ),
            onBindConflict: (_) async => false,
          );

      expect(result.outcome, LoginOutcome.success);
      expect(requests.map((request) => request.url.path), <String>[
        '/wocloud_v2/appUser/appLogin.bin',
        '/gportal/app/queryAuthState',
        '/gportal/app/authLogin',
      ]);
    },
  );

  test('APad account failure stops before Portal auth', () async {
    final paths = <String>[];
    final client = MockClient((http.Request request) async {
      paths.add(request.url.path);
      if (request.url.path == '/wocloud_v2/appUser/appLogin.bin') {
        return _jsonResponse(<String, dynamic>{
          'resultCode': 10,
          'resultMsg': '该账号仅支持手机',
          'data': null,
        });
      }
      fail('Portal request should not run after account failure');
    });

    final result =
        await GiWifiClient(
          clientFactory: () => client,
          appPortalProbeUrl: '',
          appNetworkIdentityResolver: (_) async => const AppNetworkIdentity(
            userIp: '10.0.0.42',
            userMac: 'AA:BB:CC:DD:EE:FF',
          ),
        ).login(
          baseUrl: 'http://10.100.100.2',
          profile: DeviceProfile.apad,
          username: 'account',
          password: 'secret',
          onBindConflict: (_) async => false,
        );

    expect(result.outcome, LoginOutcome.failure);
    expect(result.info, '该账号仅支持手机');
    expect(paths, <String>['/wocloud_v2/appUser/appLogin.bin']);
  });

  test('service type fallback follows the configured APK categories', () async {
    final serviceTypes = <String>[];
    final client = MockClient((http.Request request) async {
      if (request.url.path == '/wocloud_v2/appUser/appLogin.bin') {
        final envelope = _decodeAccountRequest(request);
        serviceTypes.add(_decrypt(envelope.inner['service_type']!));
        final succeeded = serviceTypes.length == 2;
        return _jsonResponse(<String, dynamic>{
          'resultCode': succeeded ? 0 : 10,
          'resultMsg': succeeded ? '登录成功' : '服务类型不匹配',
          'data': '',
        });
      }
      if (request.url.path.endsWith('queryAuthState')) {
        return _jsonResponse(<String, dynamic>{
          'resultCode': 0,
          // The client treats 2/200 as already authenticated.  Returning the
          // online state keeps this test focused on the account-layer retry
          // sequence and avoids an unrelated authLogin request.
          'data': <String, dynamic>{'authState': 2},
        });
      }
      fail('authLogin is not expected while authState is online');
    });

    final result =
        await GiWifiClient(
          clientFactory: () => client,
          appPortalProbeUrl: '',
          appNetworkIdentityResolver: (_) async => const AppNetworkIdentity(
            userIp: '10.0.0.42',
            userMac: 'AA:BB:CC:DD:EE:FF',
          ),
        ).login(
          baseUrl: 'http://10.100.100.2',
          profile: DeviceProfile.apad,
          username: 'account',
          password: 'secret',
          appAccountOptions: const AppAccountLoginOptions(
            serviceType: 1,
            fallbackServiceTypes: <int>[2],
          ),
          onBindConflict: (_) async => false,
        );

    expect(result.outcome, LoginOutcome.success);
    expect(serviceTypes, <String>['1', '2']);
  });
}

String _encrypted(String value) => encryptAppPortalPayload(value);

// Account-layer fields live in JSON as raw Base64.  Unlike the App Portal
// `data` field, they have not crossed Java's form-url-encoding boundary, so a
// literal `+` remains a Base64 character rather than meaning a space.  Encode
// it once before using the shared form-aware decoder.
String _decrypt(String value) => decryptAppPortalData(javaFormUrlEncode(value));

http.Response _jsonResponse(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: const <String, String>{'content-type': 'application/json'},
);

({Map<String, dynamic> outer, Map<String, String> inner}) _decodeAccountRequest(
  http.Request request,
) {
  final outer = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
  final data = outer['data'];
  expect(data, isA<String>());
  final inner = Map<String, String>.from(
    (jsonDecode(data as String) as Map).map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    ),
  );
  return (outer: outer, inner: inner);
}

Map<String, String> _decodePortalRequest(http.Request request) {
  final encoded = request.bodyFields['data'];
  expect(encoded, isNotNull);
  final plaintext = decryptAppPortalData(encoded!);
  final values = <String, String>{};
  for (final pair in plaintext.split('&')) {
    final separator = pair.indexOf('=');
    if (separator < 0) {
      continue;
    }
    values[pair.substring(0, separator)] = javaFormUrlDecode(
      pair.substring(separator + 1),
    );
  }
  return values;
}
