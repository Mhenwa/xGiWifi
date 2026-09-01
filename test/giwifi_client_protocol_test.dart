import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xgiwifi/giwifi/app_network_identity.dart';
import 'package:xgiwifi/giwifi/giwifi_client.dart';
import 'package:xgiwifi/giwifi/giwifi_models.dart';

void main() {
  group('App Portal login', () {
    for (final fixture
        in <
          ({
            DeviceProfile profile,
            String btype,
            String staType,
            String staModel,
          })
        >[
          (
            profile: DeviceProfile.android,
            btype: '1',
            staType: 'phone',
            staModel: 'Google,Pixel 9,35,15',
          ),
          (
            profile: DeviceProfile.apad,
            btype: '2',
            staType: 'pad',
            staModel: 'samsung,SM-T870,34,14',
          ),
        ]) {
      test('${fixture.profile.name} uses current app auth protocol', () async {
        final requests = <http.Request>[];
        final client = MockClient((http.Request request) async {
          requests.add(request);

          if (request.method == 'GET') {
            expect(request.url.path, '/gportal/web/login');
            return http.Response(_appContextHtml, 200);
          }

          expect(
            request.headers['content-type'],
            'application/x-www-form-urlencoded',
          );
          expect(request.headers['connection'], 'Keep-Alive');
          expect(request.headers['user-agent'], 'okhttp/3.8.0');
          final fields = _decodeAppRequest(request);
          if (request.url.path == '/gportal/app/queryAuthState') {
            expect(fields, <String, String>{
              'timestamp': '1760000000',
              'userIp': '10.0.0.42',
              'userName': 'test-user',
              'sign': fields['sign']!,
            });
            expect(fields['sign'], '9aa52ef814b26cfbd8c005610870be47');
            expect(request.bodyFields['data'], contains('%'));
            expect(request.body, contains('%25'));
            return _jsonResponse(
              _appResponse(<String, dynamic>{
                'resultCode': 0,
                'resultMsg': 'state ok',
                'data': <String, dynamic>{
                  'authState': 1,
                  'userMac': 'AA:BB:CC:DD:EE:FF',
                  'nasName': 'NAS-FROM-STATE',
                },
              }),
            );
          }

          expect(request.url.path, '/gportal/app/authLogin');
          expect(fields['appUuid'], '12345678-1234-1234-123456789abc');
          expect(fields['userIp'], '10.0.0.42');
          expect(fields['userMac'], 'AA:BB:CC:DD:EE:FF');
          expect(fields['nasName'], 'NAS-FROM-STATE');
          expect(fields['userName'], 'test-user');
          expect(fields['passwd'], 'p@ss word&1');
          expect(fields['btype'], fixture.btype);
          expect(fields['staType'], fixture.staType);
          expect(fields['staModel'], fixture.staModel);
          expect(fields['vlan'], '1');
          expect(fields['ssid'], isEmpty);
          expect(fields['nasIp'], isEmpty);
          expect(fields['apMac'], isEmpty);
          expect(fields['userFirstUrl'], isEmpty);
          expect(fields['timestamp'], '1760000000');
          expect(fields['sign'], hasLength(32));
          final successTip = fixture.profile == DeviceProfile.apad
              ? '平板认证成功'
              : '';
          return _jsonResponse(
            _appResponse(<String, dynamic>{
              'resultCode': 0,
              'resultMsg': '登录成功',
              'data': <String, dynamic>{'tips': successTip},
            }),
          );
        });

        final result =
            await GiWifiClient(
              clientFactory: () => client,
              epochSeconds: () => 1760000000,
              appPortalProbeUrl: '',
              appNetworkIdentityResolver: (_) async => _fixtureIdentity,
              appAccountOptions: const AppAccountLoginOptions(enabled: false),
            ).login(
              baseUrl: 'http://10.100.100.2',
              profile: fixture.profile,
              username: 'test-user',
              password: 'p@ss word&1',
              appUuid: '12345678-1234-1234-123456789abc',
              onBindConflict: (_) async => false,
            );

        expect(result.outcome, LoginOutcome.success);
        expect(
          result.info,
          fixture.profile == DeviceProfile.apad ? '平板认证成功' : '登录成功',
        );
        expect(result.session?.profile, fixture.profile);
        expect(result.session?.ip, '10.0.0.42');
        expect(
          requests.map((http.Request request) => request.url.path),
          <String>['/gportal/app/queryAuthState', '/gportal/app/authLogin'],
        );
      });
    }

    test('resultCode 43 uses app reBindMac then retries authLogin', () async {
      var authAttempts = 0;
      var bindPrompts = 0;
      var contextFetches = 0;
      var stateQueries = 0;
      final paths = <String>[];
      final delays = <Duration>[];
      final client = MockClient((http.Request request) async {
        paths.add(request.url.path);
        if (request.method == 'GET') {
          contextFetches++;
          return http.Response(
            contextFetches == 1 ? _appContextHtml : _refreshedAppContextHtml,
            200,
          );
        }

        final fields = _decodeAppRequest(request);
        if (request.url.path == '/gportal/app/queryAuthState') {
          stateQueries++;
          expect(
            fields['userIp'],
            stateQueries == 1 ? '10.0.0.42' : '10.0.0.43',
          );
          return _jsonResponse(
            _appResponse(<String, dynamic>{
              'resultCode': 0,
              'resultMsg': 'ok',
              'data': <String, dynamic>{
                'authState': 1,
                'userMac': stateQueries == 1
                    ? 'AA:BB:CC:DD:EE:FF'
                    : '11:22:33:44:55:66',
                'nasName': stateQueries == 1 ? 'NAS-1' : 'NAS-2',
              },
            }),
          );
        }

        expect(fields['btype'], '2');
        expect(fields['staType'], 'pad');
        if (request.url.path == '/gportal/app/reBindMac') {
          expect(fields.keys.toSet(), <String>{
            'appUuid',
            'nasName',
            'userMac',
            'userIp',
            'btype',
            'staType',
            'staModel',
            'userName',
            'passwd',
            'timestamp',
            'sign',
          });
          expect(fields['appUuid'], '12345678-1234-1234-123456789abc');
          expect(fields['nasName'], 'NAS-1');
          expect(fields['userMac'], 'AA:BB:CC:DD:EE:FF');
          expect(fields['userIp'], '10.0.0.42');
          expect(fields['staModel'], 'samsung,SM-T870,34,14');
          expect(fields['userName'], 'test-user');
          expect(fields['passwd'], 'secret');
          expect(fields['timestamp'], '1760000000');
          expect(fields['sign'], hasLength(32));
          return _jsonResponse(
            _appResponse(<String, dynamic>{
              'resultCode': 0,
              'resultMsg': '换绑成功',
              'data': <String, dynamic>{},
            }),
          );
        }

        authAttempts++;
        expect(
          fields['userMac'],
          authAttempts == 1 ? 'AA:BB:CC:DD:EE:FF' : '11:22:33:44:55:66',
        );
        expect(fields['nasName'], 'NAS-1');
        expect(fields['userIp'], authAttempts == 1 ? '10.0.0.42' : '10.0.0.43');
        return _jsonResponse(
          _appResponse(<String, dynamic>{
            'resultCode': authAttempts == 1 ? 43 : 0,
            'resultMsg': authAttempts == 1 ? '需要绑定当前设备' : '登录成功',
            'data': <String, dynamic>{},
          }),
        );
      });

      final result =
          await GiWifiClient(
            clientFactory: () => client,
            epochSeconds: () => 1760000000,
            appPortalProbeUrl: '',
            appNetworkIdentityResolver: (_) async {
              contextFetches++;
              return AppNetworkIdentity(
                userIp: contextFetches == 1 ? '10.0.0.42' : '10.0.0.43',
                userMac: '',
                interfaceName: 'wlan0',
              );
            },
            appAccountOptions: const AppAccountLoginOptions(enabled: false),
            delay: (Duration duration) async {
              delays.add(duration);
            },
          ).login(
            baseUrl: 'http://10.100.100.2',
            profile: DeviceProfile.apad,
            username: 'test-user',
            password: 'secret',
            appUuid: '12345678-1234-1234-123456789abc',
            onBindConflict: (_) async {
              bindPrompts++;
              return true;
            },
          );

      expect(result.outcome, LoginOutcome.success);
      expect(bindPrompts, 1);
      expect(authAttempts, 2);
      expect(contextFetches, 2);
      expect(stateQueries, 2);
      expect(delays, <Duration>[const Duration(seconds: 4)]);
      expect(paths, <String>[
        '/gportal/app/queryAuthState',
        '/gportal/app/authLogin',
        '/gportal/app/reBindMac',
        '/gportal/app/queryAuthState',
        '/gportal/app/authLogin',
      ]);
    });

    test(
      'rebind keeps discovered Portal origin when second probe fails',
      () async {
        var probeRequests = 0;
        var resolverCalls = 0;
        var stateQueries = 0;
        var authAttempts = 0;
        final requestUrls = <String>[];
        final client = MockClient((http.Request request) async {
          requestUrls.add(request.url.toString());
          if (request.method == 'GET') {
            probeRequests++;
            expect(request.url, Uri.parse('http://115.159.209.137'));
            expect(request.followRedirects, isFalse);
            if (probeRequests == 1) {
              return http.Response(
                '',
                302,
                headers: <String, String>{
                  'location':
                      'http://portal.example:9090/gportal/web/login?'
                      'wlanacname=NAS-STICKY',
                },
              );
            }
            return http.Response('', 204);
          }

          expect(request.url.origin, 'http://portal.example:9090');
          final fields = _decodeAppRequest(request);
          if (request.url.path == '/gportal/app/queryAuthState') {
            stateQueries++;
            expect(
              fields['userIp'],
              stateQueries == 1 ? '10.0.0.42' : '10.0.0.43',
            );
            return _jsonResponse(
              _appResponse(<String, dynamic>{
                'resultCode': 0,
                'resultMsg': 'state ok',
                'data': <String, dynamic>{'authState': 1},
              }),
            );
          }

          expect(fields['nasName'], 'NAS-STICKY');
          if (request.url.path == '/gportal/app/reBindMac') {
            expect(fields['userIp'], '10.0.0.42');
            return _jsonResponse(
              _appResponse(<String, dynamic>{
                'resultCode': 0,
                'resultMsg': '换绑成功',
                'data': <String, dynamic>{},
              }),
            );
          }

          expect(request.url.path, '/gportal/app/authLogin');
          authAttempts++;
          expect(
            fields['userIp'],
            authAttempts == 1 ? '10.0.0.42' : '10.0.0.43',
          );
          return _jsonResponse(
            _appResponse(<String, dynamic>{
              'resultCode': authAttempts == 1 ? 43 : 0,
              'resultMsg': authAttempts == 1 ? '需要绑定当前设备' : '登录成功',
              'data': <String, dynamic>{},
            }),
          );
        });

        final result =
            await GiWifiClient(
              clientFactory: () => client,
              epochSeconds: () => 1760000000,
              appPortalProbeUrl: 'http://115.159.209.137',
              appNetworkIdentityResolver: (Uri portalUri) async {
                resolverCalls++;
                expect(portalUri.origin, 'http://portal.example:9090');
                expect(portalUri.queryParameters['wlanacname'], 'NAS-STICKY');
                return AppNetworkIdentity(
                  userIp: resolverCalls == 1 ? '10.0.0.42' : '10.0.0.43',
                  userMac: resolverCalls == 1
                      ? 'AA:BB:CC:DD:EE:FF'
                      : '11:22:33:44:55:66',
                  interfaceName: 'wlan0',
                );
              },
              appAccountOptions: const AppAccountLoginOptions(enabled: false),
              delay: (_) async {},
            ).login(
              baseUrl: 'http://configured.example:8080',
              profile: DeviceProfile.apad,
              username: 'test-user',
              password: 'secret',
              appUuid: '12345678-1234-1234-123456789abc',
              onBindConflict: (_) async => true,
            );

        expect(result.outcome, LoginOutcome.success);
        expect(result.session?.ip, '10.0.0.43');
        expect(probeRequests, 2);
        expect(resolverCalls, 2);
        expect(stateQueries, 2);
        expect(authAttempts, 2);
        expect(requestUrls, <String>[
          'http://115.159.209.137',
          'http://portal.example:9090/gportal/app/queryAuthState',
          'http://portal.example:9090/gportal/app/authLogin',
          'http://portal.example:9090/gportal/app/reBindMac',
          'http://115.159.209.137',
          'http://portal.example:9090/gportal/app/queryAuthState',
          'http://portal.example:9090/gportal/app/authLogin',
        ]);
      },
    );

    test(
      'fresh Portal discovery after rebind replaces the fallback cache',
      () async {
        var probeRequests = 0;
        var stateRequests = 0;
        final apiOrigins = <String>[];
        final resolverOrigins = <String>[];

        Future<http.Response> handleRequest(http.Request request) async {
          if (request.method == 'GET') {
            probeRequests++;
            expect(request.url, Uri.parse('http://115.159.209.137'));
            expect(request.followRedirects, isFalse);
            switch (probeRequests) {
              case 1:
                return http.Response(
                  '',
                  302,
                  headers: const <String, String>{
                    'location':
                        'http://portal-a.example:9090/gportal/web/login?'
                        'wlanacname=NAS-A',
                  },
                );
              case 2:
                // Rebind supplies portal A as a fallback, but a fresh
                // redirect has now identified portal B.  B must replace the
                // retained process-cache origin.
                return http.Response(
                  '',
                  302,
                  headers: const <String, String>{
                    'location':
                        'http://portal-b.example:9191/gportal/web/login?'
                        'wlanacname=NAS-B',
                  },
                );
              case 3:
                // Authenticated probes carry no redirect; this login must
                // use the last freshly discovered Portal (B), not fallback A.
                return http.Response(r'{"resultCode":0,"data":"\"\""}', 200);
              default:
                fail('Unexpected discovery probe $probeRequests');
            }
          }

          apiOrigins.add(request.url.origin);
          if (request.url.path == '/gportal/app/queryAuthState') {
            stateRequests++;
            return _jsonResponse(
              _appResponse(<String, dynamic>{
                'resultCode': 0,
                'data': <String, dynamic>{
                  'authState': stateRequests == 1 ? 1 : 2,
                },
              }),
            );
          }

          if (request.url.path == '/gportal/app/authLogin') {
            expect(request.url.origin, 'http://portal-a.example:9090');
            return _jsonResponse(
              _appResponse(<String, dynamic>{
                'resultCode': 43,
                'resultMsg': '需要绑定当前设备',
                'data': <String, dynamic>{},
              }),
            );
          }

          expect(request.url.path, '/gportal/app/reBindMac');
          expect(request.url.origin, 'http://portal-a.example:9090');
          return _jsonResponse(
            _appResponse(<String, dynamic>{
              'resultCode': 0,
              'data': <String, dynamic>{},
            }),
          );
        }

        final client = GiWifiClient(
          clientFactory: () => MockClient(handleRequest),
          epochSeconds: () => 1760000000,
          appPortalProbeUrl: 'http://115.159.209.137',
          appNetworkIdentityResolver: (Uri portalUri) async {
            resolverOrigins.add(portalUri.origin);
            return const AppNetworkIdentity(
              userIp: '10.0.0.42',
              userMac: 'AA:BB:CC:DD:EE:FF',
              interfaceName: 'wlan0',
            );
          },
          appAccountOptions: const AppAccountLoginOptions(enabled: false),
          delay: (_) async {},
        );

        Future<LoginResult> login() => client.login(
          baseUrl: 'http://configured.example:8080',
          profile: DeviceProfile.apad,
          username: 'test-user',
          password: 'secret',
          appUuid: '12345678-1234-1234-123456789abc',
          onBindConflict: (_) async => true,
        );

        final rebindResult = await login();
        final cachedResult = await login();

        expect(rebindResult.outcome, LoginOutcome.success);
        expect(cachedResult.outcome, LoginOutcome.success);
        expect(probeRequests, 3);
        expect(resolverOrigins, <String>[
          'http://portal-a.example:9090',
          'http://portal-b.example:9191',
          'http://portal-b.example:9191',
        ]);
        expect(apiOrigins, <String>[
          'http://portal-a.example:9090',
          'http://portal-a.example:9090',
          'http://portal-a.example:9090',
          'http://portal-b.example:9191',
          'http://portal-b.example:9191',
        ]);
      },
    );

    for (final fixture in <({int authState, String expectedInfo})>[
      (authState: 2, expectedInfo: '当前终端已认证在线'),
      (authState: 200, expectedInfo: '认证已建立，但当前外网状态异常'),
    ]) {
      test('authState ${fixture.authState} skips authLogin', () async {
        final paths = <String>[];
        final client = MockClient((http.Request request) async {
          paths.add(request.url.path);
          if (request.method == 'GET') {
            return http.Response(_appContextHtml, 200);
          }

          expect(request.url.path, '/gportal/app/queryAuthState');
          return _jsonResponse(
            _appResponse(<String, dynamic>{
              'resultCode': 0,
              'resultMsg': 'state ok',
              'data': <String, dynamic>{
                'authState': fixture.authState,
                'userMac': 'AA:BB:CC:DD:EE:FF',
                'nasName': 'NAS-ONLINE',
              },
            }),
          );
        });

        final result =
            await GiWifiClient(
              clientFactory: () => client,
              epochSeconds: () => 1760000000,
              appPortalProbeUrl: '',
              appNetworkIdentityResolver: (_) async => _fixtureIdentity,
              appAccountOptions: const AppAccountLoginOptions(enabled: false),
            ).login(
              baseUrl: 'http://10.100.100.2',
              profile: DeviceProfile.apad,
              username: 'test-user',
              password: 'secret',
              appUuid: '12345678-1234-1234-123456789abc',
              onBindConflict: (_) async => false,
            );

        expect(result.outcome, LoginOutcome.success);
        expect(result.info, fixture.expectedInfo);
        expect(result.session?.ip, '10.0.0.42');
        expect(paths, <String>['/gportal/app/queryAuthState']);
      });
    }

    test('rebind authState 2 skips a second authLogin', () async {
      var authAttempts = 0;
      var stateQueries = 0;
      final paths = <String>[];
      final delays = <Duration>[];
      final client = MockClient((http.Request request) async {
        paths.add(request.url.path);
        if (request.method == 'GET') {
          return http.Response(_appContextHtml, 200);
        }

        if (request.url.path == '/gportal/app/queryAuthState') {
          stateQueries++;
          return _jsonResponse(
            _appResponse(<String, dynamic>{
              'resultCode': 0,
              'resultMsg': 'state ok',
              'data': <String, dynamic>{
                'authState': stateQueries == 1 ? 1 : 2,
                'userMac': 'AA:BB:CC:DD:EE:FF',
                'nasName': 'NAS-1',
              },
            }),
          );
        }

        if (request.url.path == '/gportal/app/reBindMac') {
          return _jsonResponse(
            _appResponse(<String, dynamic>{
              'resultCode': 0,
              'resultMsg': '换绑成功',
              'data': <String, dynamic>{},
            }),
          );
        }

        expect(request.url.path, '/gportal/app/authLogin');
        authAttempts++;
        return _jsonResponse(
          _appResponse(<String, dynamic>{
            'resultCode': 43,
            'resultMsg': '需要绑定当前设备',
            'data': <String, dynamic>{},
          }),
        );
      });

      final result =
          await GiWifiClient(
            clientFactory: () => client,
            epochSeconds: () => 1760000000,
            appPortalProbeUrl: '',
            appNetworkIdentityResolver: (_) async => _fixtureIdentity,
            appAccountOptions: const AppAccountLoginOptions(enabled: false),
            delay: (Duration duration) async {
              delays.add(duration);
            },
          ).login(
            baseUrl: 'http://10.100.100.2',
            profile: DeviceProfile.apad,
            username: 'test-user',
            password: 'secret',
            appUuid: '12345678-1234-1234-123456789abc',
            onBindConflict: (_) async => true,
          );

      expect(result.outcome, LoginOutcome.success);
      expect(result.info, '当前终端已认证在线');
      expect(authAttempts, 1);
      expect(stateQueries, 2);
      expect(delays, <Duration>[const Duration(seconds: 4)]);
      expect(paths, <String>[
        '/gportal/app/queryAuthState',
        '/gportal/app/authLogin',
        '/gportal/app/reBindMac',
        '/gportal/app/queryAuthState',
      ]);
    });

    test('direct resultCode envelope is not treated as ciphertext', () async {
      var bindPrompts = 0;
      final paths = <String>[];
      final client = MockClient((http.Request request) async {
        paths.add(request.url.path);
        if (request.method == 'GET') {
          return http.Response(_appContextHtml, 200);
        }

        if (request.url.path == '/gportal/app/queryAuthState') {
          return _jsonResponse(
            _appResponse(<String, dynamic>{
              'resultCode': 0,
              'resultMsg': 'state ok',
              'data': <String, dynamic>{
                'authState': 1,
                'userMac': 'AA:BB:CC:DD:EE:FF',
                'nasName': 'NAS-1',
              },
            }),
          );
        }

        expect(request.url.path, '/gportal/app/authLogin');
        return _jsonResponse(
          jsonEncode(<String, dynamic>{
            'resultCode': 43,
            'resultMsg': '需要绑定当前设备',
            'data': 'opaque-result-data',
          }),
        );
      });

      final result =
          await GiWifiClient(
            clientFactory: () => client,
            epochSeconds: () => 1760000000,
            appPortalProbeUrl: '',
            appNetworkIdentityResolver: (_) async => _fixtureIdentity,
            appAccountOptions: const AppAccountLoginOptions(enabled: false),
          ).login(
            baseUrl: 'http://10.100.100.2',
            profile: DeviceProfile.apad,
            username: 'test-user',
            password: 'secret',
            appUuid: '12345678-1234-1234-123456789abc',
            onBindConflict: (String message) async {
              bindPrompts++;
              expect(message, '需要绑定当前设备');
              return false;
            },
          );

      expect(result.outcome, LoginOutcome.cancelled);
      expect(bindPrompts, 1);
      expect(paths, <String>[
        '/gportal/app/queryAuthState',
        '/gportal/app/authLogin',
      ]);
    });

    test('parses APK resultData failure envelope and preserves info', () async {
      final paths = <String>[];
      final client = MockClient((http.Request request) async {
        paths.add(request.url.path);
        final fields = _decodeAppRequest(request);
        if (request.url.path == '/gportal/app/queryAuthState') {
          return _jsonResponse(
            _appResponse(<String, dynamic>{
              'resultCode': 0,
              'resultMsg': 'state ok',
              'data': <String, dynamic>{
                'authState': 1,
                'userMac': 'AA:BB:CC:DD:EE:FF',
              },
            }),
          );
        }

        expect(request.url.path, '/gportal/app/authLogin');
        expect(fields['btype'], '2');
        return _jsonResponse(
          jsonEncode(<String, dynamic>{
            'data': <String, dynamic>{'resultCode': 123, 'resultData': null},
            'info': '该账户套餐不支持本类型设备使用!',
            'status': 0,
          }),
        );
      });

      final result =
          await GiWifiClient(
            clientFactory: () => client,
            epochSeconds: () => 1760000000,
            appPortalProbeUrl: '',
            appNetworkIdentityResolver: (_) async => _fixtureIdentity,
            appAccountOptions: const AppAccountLoginOptions(enabled: false),
          ).login(
            baseUrl: 'http://10.100.100.2',
            profile: DeviceProfile.apad,
            username: 'test-user',
            password: 'secret',
            appUuid: '12345678-1234-1234-123456789abc',
            onBindConflict: (_) async => false,
          );

      expect(result.outcome, LoginOutcome.failure);
      expect(result.info, '该账户套餐不支持本类型设备使用!');
      expect(paths, <String>[
        '/gportal/app/queryAuthState',
        '/gportal/app/authLogin',
      ]);
      expect(
        paths.where((String path) => path.toLowerCase().contains('/web/')),
        isEmpty,
      );
    });

    test(
      'fills missing local MAC from queryAuthState before authLogin',
      () async {
        final paths = <String>[];
        var resolverCalls = 0;
        final client = MockClient((http.Request request) async {
          paths.add(request.url.path);
          final fields = _decodeAppRequest(request);
          if (request.url.path == '/gportal/app/queryAuthState') {
            expect(fields.containsKey('userMac'), isFalse);
            return _jsonResponse(
              _appResponse(<String, dynamic>{
                'resultCode': 0,
                'resultMsg': 'state ok',
                'data': <String, dynamic>{
                  'authState': 1,
                  'userMac': 'aa:bb:cc:dd:ee:ff',
                  'nasName': 'NAS-FROM-STATE',
                },
              }),
            );
          }

          expect(request.url.path, '/gportal/app/authLogin');
          expect(fields['userMac'], 'AA:BB:CC:DD:EE:FF');
          expect(fields['nasName'], 'NAS-FROM-STATE');
          return _jsonResponse(
            _appResponse(<String, dynamic>{
              'resultCode': 0,
              'resultMsg': '登录成功',
              'data': <String, dynamic>{},
            }),
          );
        });

        final result =
            await GiWifiClient(
              clientFactory: () => client,
              epochSeconds: () => 1760000000,
              appPortalProbeUrl: '',
              appNetworkIdentityResolver: (_) async {
                resolverCalls++;
                return const AppNetworkIdentity(
                  userIp: '10.0.0.42',
                  userMac: '',
                  interfaceName: 'wlan0',
                );
              },
              appAccountOptions: const AppAccountLoginOptions(enabled: false),
            ).login(
              baseUrl: 'http://10.100.100.2',
              profile: DeviceProfile.android,
              username: 'test-user',
              password: 'secret',
              appUuid: '12345678-1234-1234-123456789abc',
              onBindConflict: (_) async => false,
            );

        expect(result.outcome, LoginOutcome.success);
        expect(result.session?.ip, '10.0.0.42');
        expect(resolverCalls, 1);
        expect(paths, <String>[
          '/gportal/app/queryAuthState',
          '/gportal/app/authLogin',
        ]);
        expect(
          paths.where((String path) => path.toLowerCase().contains('/web/')),
          isEmpty,
        );
      },
    );

    test(
      'sends authLogin with empty userMac when no usable MAC is available',
      () async {
        final paths = <String>[];
        final client = MockClient((http.Request request) async {
          paths.add(request.url.path);
          final fields = _decodeAppRequest(request);
          if (request.url.path == '/gportal/app/queryAuthState') {
            expect(fields.containsKey('userMac'), isFalse);
            return _jsonResponse(
              _appResponse(<String, dynamic>{
                'resultCode': 0,
                'resultMsg': 'state ok',
                'data': <String, dynamic>{
                  'authState': 1,
                  'userMac': '02:00:00:00:00:00',
                  'nasName': 'NAS-FROM-STATE',
                },
              }),
            );
          }

          expect(request.url.path, '/gportal/app/authLogin');
          expect(fields['userMac'], isEmpty);
          expect(fields['nasName'], 'NAS-FROM-STATE');
          return _jsonResponse(
            _appResponse(<String, dynamic>{
              'resultCode': 0,
              'resultMsg': '登录成功',
              'data': <String, dynamic>{},
            }),
          );
        });

        final result =
            await GiWifiClient(
              clientFactory: () => client,
              epochSeconds: () => 1760000000,
              appPortalProbeUrl: '',
              appNetworkIdentityResolver: (_) async => const AppNetworkIdentity(
                userIp: '10.0.0.42',
                userMac: '',
                interfaceName: 'wlan0',
              ),
              appAccountOptions: const AppAccountLoginOptions(enabled: false),
            ).login(
              baseUrl: 'http://10.100.100.2',
              profile: DeviceProfile.android,
              username: 'test-user',
              password: 'secret',
              appUuid: '12345678-1234-1234-123456789abc',
              onBindConflict: (_) async => false,
            );

        expect(result.outcome, LoginOutcome.success);
        expect(paths, <String>[
          '/gportal/app/queryAuthState',
          '/gportal/app/authLogin',
        ]);
      },
    );

    test('discovers APK Portal origin from a non-followed redirect', () async {
      final requests = <http.Request>[];
      final client = MockClient((http.Request request) async {
        requests.add(request);
        if (request.method == 'GET') {
          expect(request.url, Uri.parse('http://115.159.209.137'));
          expect(request.followRedirects, isFalse);
          expect(
            request.headers['User-Agent'],
            startsWith('Mozilla/5.0 (Linux; U; Android 11; zh-cn;'),
          );
          return http.Response(
            '',
            302,
            headers: <String, String>{
              'location':
                  'http://portal.example:9090/gportal/web/login?'
                  'wlanuserip=10.0.0.77&wlanacname=GIWIFI-BAS',
            },
          );
        }

        expect(request.url.origin, 'http://portal.example:9090');
        final fields = _decodeAppRequest(request);
        if (request.url.path == '/gportal/app/queryAuthState') {
          expect(fields['userIp'], '10.0.0.42');
          return _jsonResponse(
            _appResponse(<String, dynamic>{
              'resultCode': 0,
              'resultMsg': 'state ok',
              'data': <String, dynamic>{
                'authState': 1,
                'userMac': 'AA:BB:CC:DD:EE:FF',
              },
            }),
          );
        }

        expect(request.url.path, '/gportal/app/authLogin');
        expect(fields['userIp'], '10.0.0.42');
        expect(fields['nasName'], 'giwifi-bas');
        expect(fields['userMac'], 'AA:BB:CC:DD:EE:FF');
        return _jsonResponse(
          _appResponse(<String, dynamic>{
            'resultCode': 0,
            'resultMsg': '登录成功',
            'data': <String, dynamic>{'tips': '重定向 Portal 认证成功'},
          }),
        );
      });

      final result =
          await GiWifiClient(
            clientFactory: () => client,
            epochSeconds: () => 1760000000,
            appPortalProbeUrl: 'http://115.159.209.137',
            appNetworkIdentityResolver: (_) async => _fixtureIdentity,
            appAccountOptions: const AppAccountLoginOptions(enabled: false),
          ).login(
            baseUrl: 'http://probe.example:8080',
            profile: DeviceProfile.apad,
            username: 'test-user',
            password: 'secret',
            appUuid: '12345678-1234-1234-123456789abc',
            onBindConflict: (_) async => false,
          );

      expect(result.outcome, LoginOutcome.success);
      expect(result.info, '重定向 Portal 认证成功');
      expect(result.session?.ip, '10.0.0.42');
      expect(
        requests.map((http.Request request) => request.url.toString()),
        <String>[
          'http://115.159.209.137',
          'http://portal.example:9090/gportal/app/queryAuthState',
          'http://portal.example:9090/gportal/app/authLogin',
        ],
      );
      expect(
        requests.where(
          (http.Request request) =>
              request.url.path.toLowerCase().contains('/gportal/web/'),
        ),
        isEmpty,
      );
    });

    test('discovers APK Portal origin from a 301 captive redirect', () async {
      final requests = <http.Request>[];
      final client = MockClient((http.Request request) async {
        requests.add(request);
        if (request.method == 'GET') {
          expect(request.followRedirects, isFalse);
          return http.Response(
            '',
            301,
            headers: <String, String>{
              'location':
                  'http://portal.example:9090/gportal/web/login?'
                  'wlanuserip=10.0.0.77&wlanacname=GIWIFI-BAS',
            },
          );
        }

        expect(request.url.origin, 'http://portal.example:9090');
        final fields = _decodeAppRequest(request);
        expect(fields['userIp'], '10.0.0.42');
        if (request.url.path == '/gportal/app/queryAuthState') {
          return _jsonResponse(
            _appResponse(<String, dynamic>{
              'resultCode': 0,
              'resultMsg': 'state ok',
              'data': <String, dynamic>{'authState': 1},
            }),
          );
        }

        expect(request.url.path, '/gportal/app/authLogin');
        return _jsonResponse(
          _appResponse(<String, dynamic>{
            'resultCode': 0,
            'resultMsg': '登录成功',
            'data': <String, dynamic>{},
          }),
        );
      });

      final result =
          await GiWifiClient(
            clientFactory: () => client,
            epochSeconds: () => 1760000000,
            appPortalProbeUrl: 'http://115.159.209.137',
            appNetworkIdentityResolver: (Uri portalUri) async {
              expect(portalUri.origin, 'http://portal.example:9090');
              expect(portalUri.queryParameters['wlanacname'], 'GIWIFI-BAS');
              return _fixtureIdentity;
            },
            appAccountOptions: const AppAccountLoginOptions(enabled: false),
          ).login(
            baseUrl: 'http://configured.example:8080',
            profile: DeviceProfile.apad,
            username: 'test-user',
            password: 'secret',
            appUuid: '12345678-1234-1234-123456789abc',
            onBindConflict: (_) async => false,
          );

      expect(result.outcome, LoginOutcome.success);
      expect(result.info, '登录成功');
      expect(
        requests.map((http.Request request) => request.url.toString()),
        <String>[
          'http://115.159.209.137',
          'http://portal.example:9090/gportal/app/queryAuthState',
          'http://portal.example:9090/gportal/app/authLogin',
        ],
      );
    });

    test('discovers APK Portal origin from a 308 captive redirect', () async {
      final requests = <http.Request>[];
      final client = MockClient((http.Request request) async {
        requests.add(request);
        if (request.method == 'GET') {
          expect(request.url, Uri.parse('http://115.159.209.137'));
          expect(request.followRedirects, isFalse);
          return http.Response(
            '',
            308,
            headers: <String, String>{
              'location':
                  'http://portal.example:9090/gportal/web/login?'
                  'wlanuserip=10.0.0.77&wlanacname=GIWIFI-BAS',
            },
          );
        }

        expect(request.url.origin, 'http://portal.example:9090');
        final fields = _decodeAppRequest(request);
        if (request.url.path == '/gportal/app/queryAuthState') {
          expect(fields['userIp'], '10.0.0.42');
          return _jsonResponse(
            _appResponse(<String, dynamic>{
              'resultCode': 0,
              'resultMsg': 'state ok',
              'data': <String, dynamic>{'authState': 1},
            }),
          );
        }

        expect(request.url.path, '/gportal/app/authLogin');
        expect(fields['btype'], '2');
        expect(fields['staType'], 'pad');
        return _jsonResponse(
          _appResponse(<String, dynamic>{
            'resultCode': 0,
            'resultMsg': '登录成功',
            'data': <String, dynamic>{},
          }),
        );
      });

      final result =
          await GiWifiClient(
            clientFactory: () => client,
            epochSeconds: () => 1760000000,
            appPortalProbeUrl: 'http://115.159.209.137',
            appNetworkIdentityResolver: (Uri portalUri) async {
              expect(portalUri.origin, 'http://portal.example:9090');
              expect(portalUri.queryParameters['wlanacname'], 'GIWIFI-BAS');
              return _fixtureIdentity;
            },
            appAccountOptions: const AppAccountLoginOptions(enabled: false),
          ).login(
            baseUrl: 'http://configured.example:8080',
            profile: DeviceProfile.apad,
            username: 'test-user',
            password: 'secret',
            appUuid: '12345678-1234-1234-123456789abc',
            onBindConflict: (_) async => false,
          );

      expect(result.outcome, LoginOutcome.success);
      expect(
        requests.map((http.Request request) => request.url.toString()),
        <String>[
          'http://115.159.209.137',
          'http://portal.example:9090/gportal/app/queryAuthState',
          'http://portal.example:9090/gportal/app/authLogin',
        ],
      );
      expect(
        requests.where(
          (http.Request request) =>
              request.url.path.toLowerCase().contains('/gportal/web/'),
        ),
        isEmpty,
      );
    });

    test(
      'reuses the last discovered Portal origin when an authenticated probe is 200',
      () async {
        var probeCount = 0;
        final requests = <http.Request>[];
        http.Client clientFactory() => MockClient((http.Request request) async {
          requests.add(request);
          if (request.method == 'GET') {
            probeCount++;
            expect(request.url, Uri.parse('http://115.159.209.137'));
            expect(request.followRedirects, isFalse);
            if (probeCount == 1) {
              return http.Response(
                '',
                301,
                headers: <String, String>{
                  'location':
                      'http://portal.example:9090/gportal/web/login?'
                      'wlanacname=GIWIFI-BAS',
                },
              );
            }

            // Once the station is authenticated, the fixed probe returns the
            // origin server's normal 200 response and carries no Portal URL.
            return http.Response(
              jsonEncode(<String, dynamic>{'resultCode': 0, 'data': '""'}),
              200,
            );
          }

          expect(request.url.origin, 'http://portal.example:9090');
          final fields = _decodeAppRequest(request);
          if (request.url.path == '/gportal/app/queryAuthState') {
            expect(fields['userIp'], '10.0.0.42');
            return _jsonResponse(
              _appResponse(<String, dynamic>{
                'resultCode': 0,
                'resultMsg': 'state ok',
                'data': <String, dynamic>{'authState': 1},
              }),
            );
          }

          expect(request.url.path, '/gportal/app/authLogin');
          return _jsonResponse(
            _appResponse(<String, dynamic>{
              'resultCode': 0,
              'resultMsg': '登录成功',
              'data': <String, dynamic>{},
            }),
          );
        });

        final client = GiWifiClient(
          clientFactory: clientFactory,
          epochSeconds: () => 1760000000,
          appPortalProbeUrl: 'http://115.159.209.137',
          appNetworkIdentityResolver: (Uri portalUri) async {
            expect(portalUri.origin, 'http://portal.example:9090');
            return _fixtureIdentity;
          },
          appAccountOptions: const AppAccountLoginOptions(enabled: false),
        );

        Future<LoginResult> loginOnce() {
          return client.login(
            baseUrl: 'http://configured.example:8080',
            profile: DeviceProfile.apad,
            username: 'test-user',
            password: 'secret',
            appUuid: '12345678-1234-1234-123456789abc',
            onBindConflict: (_) async => false,
          );
        }

        expect((await loginOnce()).outcome, LoginOutcome.success);
        expect((await loginOnce()).outcome, LoginOutcome.success);

        expect(
          requests.map((http.Request request) => request.url.toString()),
          <String>[
            'http://115.159.209.137',
            'http://portal.example:9090/gportal/app/queryAuthState',
            'http://portal.example:9090/gportal/app/authLogin',
            'http://115.159.209.137',
            'http://portal.example:9090/gportal/app/queryAuthState',
            'http://portal.example:9090/gportal/app/authLogin',
          ],
        );
      },
    );

    test(
      'uses the APK canonical host when a 200 probe has the empty marker',
      () async {
        final requests = <http.Request>[];
        http.Client clientFactory() => MockClient((http.Request request) async {
          requests.add(request);
          if (request.method == 'GET') {
            expect(request.url, Uri.parse('http://115.159.209.137'));
            expect(request.followRedirects, isFalse);
            return http.Response(
              jsonEncode(<String, dynamic>{'resultCode': 0, 'data': '""'}),
              200,
            );
          }

          expect(request.url.origin, 'http://as.gwifi.com.cn');
          final fields = _decodeAppRequest(request);
          if (request.url.path == '/gportal/app/queryAuthState') {
            expect(fields['userIp'], '10.0.0.42');
            return _jsonResponse(
              _appResponse(<String, dynamic>{
                'resultCode': 0,
                'resultMsg': 'state ok',
                'data': <String, dynamic>{
                  'authState': 1,
                  'nasName': 'GIWIFI-BAS',
                },
              }),
            );
          }

          expect(request.url.path, '/gportal/app/authLogin');
          expect(fields['nasName'], 'giwifi-bas');
          return _jsonResponse(
            _appResponse(<String, dynamic>{
              'resultCode': 0,
              'resultMsg': '登录成功',
              'data': <String, dynamic>{},
            }),
          );
        });

        final result =
            await GiWifiClient(
              clientFactory: clientFactory,
              epochSeconds: () => 1760000000,
              appPortalProbeUrl: 'http://115.159.209.137',
              appNetworkIdentityResolver: (Uri portalUri) async {
                expect(portalUri.origin, 'http://as.gwifi.com.cn');
                return _fixtureIdentity;
              },
              appAccountOptions: const AppAccountLoginOptions(enabled: false),
            ).login(
              baseUrl: 'http://10.100.100.2',
              profile: DeviceProfile.apad,
              username: 'test-user',
              password: 'secret',
              appUuid: '12345678-1234-1234-123456789abc',
              onBindConflict: (_) async => false,
            );

        expect(result.outcome, LoginOutcome.success);
        expect(result.session?.resolvedPortalOrigin, 'http://as.gwifi.com.cn');
        expect(
          requests.map((http.Request request) => request.url.toString()),
          <String>[
            'http://115.159.209.137',
            'http://as.gwifi.com.cn/gportal/app/queryAuthState',
            'http://as.gwifi.com.cn/gportal/app/authLogin',
          ],
        );
      },
    );
  });

  test('Windows keeps the existing Web loginAction request contract', () async {
    final requests = <http.Request>[];
    final client = MockClient((http.Request request) async {
      requests.add(request);
      if (request.method == 'GET') {
        expect(
          request.url.toString(),
          'http://10.100.100.2/gportal/web/login?has_reload=1',
        );
        expect(request.headers['User-Agent'], DeviceProfile.windows.userAgent);
        return http.Response(
          _windowsLoginHtml,
          200,
          headers: <String, String>{
            'set-cookie': 'PHPSESSID=session-123; Path=/',
          },
        );
      }

      expect(request.url.path, '/gportal/Web/loginAction');
      expect(request.headers['Cookie'], 'PHPSESSID=session-123');
      expect(request.headers['User-Agent'], DeviceProfile.windows.userAgent);
      expect(request.body, startsWith('data='));
      expect(request.body, endsWith('&iv=1234567890abcdef'));
      return _jsonResponse(
        jsonEncode(<String, dynamic>{
          'status': 1,
          'info': '登录成功',
          'data': 'logout.html',
        }),
      );
    });

    final result = await GiWifiClient(clientFactory: () => client).login(
      baseUrl: 'http://10.100.100.2',
      profile: DeviceProfile.windows,
      username: 'test-user',
      password: 'secret',
      onBindConflict: (_) async => false,
    );

    expect(result.outcome, LoginOutcome.success);
    expect(result.session?.profile, DeviceProfile.windows);
    expect(requests, hasLength(2));
  });

  test('Windows keeps the existing bindSta retry sequence', () async {
    var loginAttempts = 0;
    var bindPrompts = 0;
    final paths = <String>[];
    final delays = <Duration>[];
    final client = MockClient((http.Request request) async {
      paths.add(request.url.path);
      if (request.method == 'GET') {
        return http.Response(
          _windowsLoginHtml,
          200,
          headers: <String, String>{
            'set-cookie': 'PHPSESSID=session-123; Path=/',
          },
        );
      }

      expect(request.headers['Cookie'], 'PHPSESSID=session-123');
      if (request.url.path == '/gportal/Web/bindSta') {
        expect(request.url.queryParameters, <String, String>{'from': 'test'});
        return _jsonResponse(
          jsonEncode(<String, dynamic>{
            'status': 1,
            'info': '换绑成功',
            'data': null,
          }),
        );
      }

      expect(request.url.path, '/gportal/Web/loginAction');
      loginAttempts++;
      if (loginAttempts == 1) {
        return _jsonResponse(
          jsonEncode(<String, dynamic>{
            'status': 0,
            'info': '需要换绑',
            'data': <String, dynamic>{
              'resultCode': 124,
              'resultData': '/gportal/Web/bindSta?from=test',
            },
          }),
        );
      }

      return _jsonResponse(
        jsonEncode(<String, dynamic>{
          'status': 1,
          'info': '登录成功',
          'data': 'logout.html',
        }),
      );
    });

    final result =
        await GiWifiClient(
          clientFactory: () => client,
          delay: (Duration duration) async {
            delays.add(duration);
          },
        ).login(
          baseUrl: 'http://10.100.100.2',
          profile: DeviceProfile.windows,
          username: 'test-user',
          password: 'secret',
          onBindConflict: (_) async {
            bindPrompts++;
            return true;
          },
        );

    expect(result.outcome, LoginOutcome.success);
    expect(bindPrompts, 1);
    expect(loginAttempts, 2);
    expect(delays, isEmpty);
    expect(paths, <String>[
      '/gportal/web/login',
      '/gportal/Web/loginAction',
      '/gportal/Web/bindSta',
      '/gportal/Web/loginAction',
    ]);
  });
}

const AppNetworkIdentity _fixtureIdentity = AppNetworkIdentity(
  userIp: '10.0.0.42',
  userMac: 'AA:BB:CC:DD:EE:FF',
  interfaceName: 'wlan0',
);

Map<String, String> _decodeAppRequest(http.Request request) {
  expect(request.headers['Content-Type'], 'application/x-www-form-urlencoded');
  expect(request.headers['User-Agent'], 'okhttp/3.8.0');
  expect(request.headers['Accept'], isNull);
  expect(request.headers['Cookie'], isNull);
  expect(request.headers['Origin'], isNull);
  final encodedData = request.bodyFields['data'];
  expect(encodedData, isNotNull);
  return Uri.splitQueryString(decryptAppPortalData(encodedData!));
}

String _appResponse(Map<String, dynamic> inner) {
  return jsonEncode(<String, dynamic>{
    'data': encodeAppPortalData(jsonEncode(inner)),
  });
}

http.Response _jsonResponse(String body) {
  return http.Response.bytes(
    utf8.encode(body),
    200,
    headers: <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );
}

const String _appContextHtml = '''
<html><body>
  <input name="sta_ip" value="10.0.0.42">
  <input name="nas_name" value="NAS-FROM-PAGE">
</body></html>
''';

const String _refreshedAppContextHtml = '''
<html><body>
  <input name="sta_ip" value="10.0.0.43">
  <input name="nas_name" value="NAS-FROM-REFRESH-PAGE">
</body></html>
''';

const String _windowsLoginHtml = '''
<html><body>
  <input name="sign" value="fixture-sign">
  <input name="sta_vlan" value="10">
  <input name="sta_port" value="1">
  <input name="sta_ip" value="10.0.0.42">
  <input name="nas_ip" value="10.0.0.1">
  <input name="nas_name" value="fixture-nas">
  <input name="last_url" value="">
  <input name="request_ip" value="198.51.100.23">
  <input name="device_mode" value="ignored">
  <input name="device_type" value="ignored">
  <input name="device_os_type" value="ignored">
  <input name="is_mobile" value="ignored">
  <input name="iv" value="1234567890abcdef">
  <input name="login_type" value="1">
  <input name="account_type" value="1">
</body></html>
''';
