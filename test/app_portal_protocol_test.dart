import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xgiwifi/giwifi/app_network_identity.dart';
import 'package:xgiwifi/giwifi/giwifi_client.dart';

void main() {
  const expectedPlaintext =
      'apMac=&appUuid=12345678-1234-1234-123456789abc&btype=2&nasIp=&nasName=NAS-1&passwd=p%40ss+word%261&ssid=&staModel=Google,Pixel Tablet,35,15&staType=pad&timestamp=1760000000&userFirstUrl=&userIp=10.0.0.42&userMac=AA:BB:CC:DD:EE:FF&userName=test-user&vlan=1&sign=2de7afc6694adae8caa76040fef00fae';
  const expectedCiphertext =
      'H++urypRIAHtigUWloSMFjf5IIulq8X3hhPIu2TpFPAudEYZeUIaGdbHL2Mrdr88502AWGllKuJSd1AgTXUnw6963IfILl4kNq08nPbk456x4Bc2v3DuWhQOn3dEFs9gGCf9OhCYs43AvYAGVR2xt9PeRuYG0HRjaW79tkU93x6wd92Vc53Q19uRtSZPUXXdKt9ZfOzeun09hutGJyr0ro4389PuQLZ549tsprshh6uowhHPmut1L7Job06HWYkM1BDgrMF5/ZDGLH54+obnlHUS8/yHOIlctp+NUpd6WlJM7ANxTcxYgYU5cLkr2dSjNugyTu6dQID35wEIAdBPudewXBEtHIsWFIbob+xZC8wpkk4gfPNBbUQ01z4D4fNWrUwLrh54jxshlslxFB1sVw==';
  const expectedEncodedCiphertext =
      'H%2B%2BurypRIAHtigUWloSMFjf5IIulq8X3hhPIu2TpFPAudEYZeUIaGdbHL2Mrdr88502AWGllKuJSd1AgTXUnw6963IfILl4kNq08nPbk456x4Bc2v3DuWhQOn3dEFs9gGCf9OhCYs43AvYAGVR2xt9PeRuYG0HRjaW79tkU93x6wd92Vc53Q19uRtSZPUXXdKt9ZfOzeun09hutGJyr0ro4389PuQLZ549tsprshh6uowhHPmut1L7Job06HWYkM1BDgrMF5%2FZDGLH54%2BobnlHUS8%2FyHOIlctp%2BNUpd6WlJM7ANxTcxYgYU5cLkr2dSjNugyTu6dQID35wEIAdBPudewXBEtHIsWFIbob%2BxZC8wpkk4gfPNBbUQ01z4D4fNWrUwLrh54jxshlslxFB1sVw%3D%3D';

  final fixtureFields = <String, String>{
    'appUuid': '12345678-1234-1234-123456789abc',
    'userIp': '10.0.0.42',
    'nasName': 'NAS-1',
    'ssid': '',
    'nasIp': '',
    'userMac': 'AA:BB:CC:DD:EE:FF',
    'vlan': '1',
    'apMac': '',
    'userFirstUrl': '',
    'userName': 'test-user',
    'passwd': 'p@ss word&1',
    'btype': '2',
    'staType': 'pad',
    'staModel': 'Google,Pixel Tablet,35,15',
    'timestamp': '1760000000',
  };

  test('App Portal payload matches independent MD5 and OpenSSL vector', () {
    final plaintext = buildAppPortalSignedPayload(
      fixtureFields,
      passwordField: 'passwd',
    );

    expect(plaintext, expectedPlaintext);
    expect(encryptAppPortalPayload(plaintext), expectedCiphertext);
    expect(encodeAppPortalData(plaintext), expectedEncodedCiphertext);
    expect(decryptAppPortalData(expectedEncodedCiphertext), expectedPlaintext);
  });

  test('Java form encoding matches URLEncoder semantics', () {
    expect(javaFormUrlEncode('p@ss word&1*~'), 'p%40ss+word%261*%7E');
    expect(javaFormUrlDecode('p%40ss+word%261*%7E'), 'p@ss word&1*~');
  });

  test('PKCS7 always adds and validates a padding block', () {
    expect(pkcs7PadToBlockSize(Uint8List(0)), hasLength(16));
    expect(pkcs7PadToBlockSize(Uint8List(15)), hasLength(16));
    expect(pkcs7PadToBlockSize(Uint8List(16)), hasLength(32));
    expect(pkcs7PadToBlockSize(Uint8List(17)), hasLength(32));

    final input = Uint8List.fromList(<int>[1, 2, 3, 4]);
    expect(pkcs7Unpad(pkcs7PadToBlockSize(input)), input);
    expect(
      () => pkcs7Unpad(Uint8List.fromList(<int>[...input, 2, 3])),
      throwsFormatException,
    );
  });

  test('normalizes gateway MAC formats before App Portal login', () {
    expect(normalizeMacAddress('aa-bb-cc-dd-ee-ff'), 'AA:BB:CC:DD:EE:FF');
    expect(normalizeMacAddress('aabb.ccdd.eeff'), 'AA:BB:CC:DD:EE:FF');
    expect(normalizeMacAddress('aabbccddeeff'), 'AA:BB:CC:DD:EE:FF');
    expect(isUsableMacAddress('AA:BB:CC:DD:EE:FF'), isTrue);
    expect(
      isUsableMacAddress(normalizeMacAddress('02-00-00-00-00-00')),
      isFalse,
    );
  });

  test('parses Linux route-get interface and source IPv4', () {
    final route = parseLinuxRouteGetOutput(
      '10.100.100.2 via 10.20.1.1 dev enp9s0 src 10.20.195.28 uid 1000\n'
      '    cache\n',
    );

    expect(route, isNotNull);
    expect(route!.interfaceName, 'enp9s0');
    expect(route.sourceIp, '10.20.195.28');
  });

  test('parses direct and reordered Linux route-get fields', () {
    final directRoute = parseLinuxRouteGetOutput(
      '192.168.238.65 dev enx56d9e15a3550 src 192.168.238.239 '
      'uid 1000 cache',
    );
    final reorderedRoute = parseLinuxRouteGetOutput(
      '10.100.100.2 src 10.20.195.28 table main dev enp9s0 uid 1000',
    );

    expect(directRoute?.interfaceName, 'enx56d9e15a3550');
    expect(directRoute?.sourceIp, '192.168.238.239');
    expect(reorderedRoute?.interfaceName, 'enp9s0');
    expect(reorderedRoute?.sourceIp, '10.20.195.28');
  });

  test('rejects incomplete or unusable Linux route-get output', () {
    expect(
      parseLinuxRouteGetOutput(
        '10.100.100.2 via 10.20.1.1 dev enp9s0 uid 1000',
      ),
      isNull,
    );
    expect(
      parseLinuxRouteGetOutput('local 127.0.0.1 dev lo src 127.0.0.1 uid 1000'),
      isNull,
    );
  });
}
