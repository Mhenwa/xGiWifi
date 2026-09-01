import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:xgiwifi/giwifi/app_network_identity.dart';
import 'package:xgiwifi/giwifi/giwifi_client.dart';
import 'package:xgiwifi/giwifi/giwifi_models.dart';

void main() {
  final liveEnabled = Platform.environment['XGIWIFI_LIVE_TEST'] == '1';
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
  final tracePrefix = 'LIVE_${profile.name.toUpperCase()}';

  test(
    'live ${profile.label} authentication over the selected GiWiFi interface',
    () async {
      final settingsPath =
          Platform.environment['XGIWIFI_SETTINGS_PATH'] ??
          '/home/mhenwa/.local/share/xgiwifi/shared_preferences.json';
      final settings = Map<String, dynamic>.from(
        jsonDecode(await File(settingsPath).readAsString()) as Map,
      );
      final username = settings['flutter.saved_account']?.toString() ?? '';
      final password = settings['flutter.saved_password']?.toString() ?? '';
      final appUuid = settings['flutter.app_uuid']?.toString() ?? '';
      final baseUrl =
          settings['flutter.base_url']?.toString() ?? 'http://10.100.100.2';
      final allowRebind =
          Platform.environment['XGIWIFI_LIVE_ALLOW_REBIND'] == '1';
      final expectedInterface =
          Platform.environment['XGIWIFI_EXPECTED_INTERFACE'] ?? 'enp9s0';

      expect(username, isNotEmpty, reason: 'No saved account is available');
      expect(password, isNotEmpty, reason: 'No saved password is available');
      expect(isGiWifiAppUuid(appUuid), isTrue);

      final traces = <String>[];
      final result =
          await GiWifiClient(
            clientFactory: () => _TraceClient(traces),
            appNetworkIdentityResolver: (Uri portalUri) async {
              final identity = await resolveAppNetworkIdentity(portalUri);
              traces.add(
                '[IDENTITY] interface=${identity.interfaceName} '
                'userIp=${identity.userIp} userMac=${identity.userMac}',
              );
              expect(
                identity.interfaceName,
                expectedInterface,
                reason:
                    'App Portal identity must follow the expected route '
                    '$expectedInterface',
              );
              return identity;
            },
          ).login(
            baseUrl: baseUrl,
            profile: profile,
            username: username,
            password: password,
            appUuid: appUuid,
            onBindConflict: (String message) async {
              traces.add('[BIND] requested; accepted=$allowRebind');
              return allowRebind;
            },
            onLog: traces.add,
          );

      for (final trace in traces) {
        // Request bodies and credentials are deliberately omitted.
        // ignore: avoid_print
        print('$tracePrefix $trace');
      }
      // ignore: avoid_print
      print(
        '$tracePrefix RESULT outcome=${result.outcome.name} '
        'info=${result.info} sessionIp=${result.session?.ip ?? "none"}',
      );

      expect(result.outcome, LoginOutcome.success, reason: result.info);
      expect(result.session?.profile, profile);
    },
    skip: liveEnabled ? false : 'Set XGIWIFI_LIVE_TEST=1 to run on GiWiFi',
    timeout: const Timeout(Duration(seconds: 45)),
  );
}

class _TraceClient extends http.BaseClient {
  _TraceClient(this.traces);

  final List<String> traces;
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    traces.add(
      '[HTTP] ${request.method} ${request.url.origin}${request.url.path} '
      'followRedirects=${request.followRedirects}',
    );
    final response = await _inner.send(request);
    final location = response.headers['location'];
    traces.add(
      '[HTTP] ${request.method} ${request.url.path} -> ${response.statusCode}'
      '${location == null ? "" : " location=${_redactLocation(location)}"}',
    );
    return response;
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}

String _redactLocation(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null) {
    return '<invalid-location>';
  }
  final nasName = uri.queryParameters['wlanacname'];
  return '${uri.origin}${uri.path}'
      '${nasName == null ? "" : "?wlanacname=$nasName"}';
}
