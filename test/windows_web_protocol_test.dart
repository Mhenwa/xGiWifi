import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xgiwifi/giwifi/giwifi_client.dart';
import 'package:xgiwifi/giwifi/giwifi_models.dart';

void main() {
  group('Windows Web Portal protocol contract', () {
    test('locks every Windows profile constant', () {
      const profile = DeviceProfile.windows;

      expect(profile.name, 'windows');
      expect(profile.label, 'Windows');
      expect(profile.protocol, DeviceProtocol.webPortal);
      expect(
        profile.userAgent,
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/146.0.0.0 Safari/537.36',
      );
      expect(profile.deviceMode, 'Windows NT 10.0');
      expect(profile.deviceType, '1');
      expect(profile.deviceOsType, '3');
      expect(profile.isMobile, '0');
      expect(profile.loginPath, '/gportal/web/login?has_reload=1');
      expect(profile.btype, '');
      expect(profile.staType, '');
      expect(profile.staModel, '');
      expect(
        profile.buildLoginUri(Uri.parse('http://10.100.100.2')).toString(),
        'http://10.100.100.2/gportal/web/login?has_reload=1',
      );
    });

    test('matches the independently calculated OpenSSL golden', () {
      const profile = DeviceProfile.windows;
      final fields = <String, String>{
        'sign': 'fixture-sign',
        'sta_vlan': '10',
        'sta_port': '1',
        'sta_ip': '10.0.0.42',
        'nas_ip': '10.0.0.1',
        'nas_name': 'fixture-nas',
        'last_url': 'http://example.test/path?x=1&y=2',
        'request_ip': '198.51.100.23',
        'device_mode': profile.deviceMode,
        'device_type': profile.deviceType,
        'device_os_type': profile.deviceOsType,
        'is_mobile': profile.isMobile,
        'iv': '1234567890abcdef',
        'login_type': '1',
        'account_type': '1',
        'user_account': 'test-user',
        'user_password': 'p@ss word&1',
      };

      final plaintext = serializePortalFields(fields);
      const expectedPlaintext =
          'sign=fixture-sign&sta_vlan=10&sta_port=1&sta_ip=10.0.0.42&'
          'nas_ip=10.0.0.1&nas_name=fixture-nas&last_url=http%3A%2F%2F'
          'example.test%2Fpath%3Fx%3D1%26y%3D2&request_ip=198.51.100.23&'
          'device_mode=Windows+NT+10.0&device_type=1&device_os_type=3&'
          'is_mobile=0&iv=1234567890abcdef&login_type=1&account_type=1&'
          'user_account=test-user&user_password=p%40ss+word%261';
      expect(plaintext, expectedPlaintext);

      final encrypted = encryptPortalPayload(
        plaintext: plaintext,
        iv: '1234567890abcdef',
      );
      const expectedCiphertext =
          'Yl32zFEEKUZ2l+WvgbeTbVsnD8haMfqmo6E2WyrdtKw0A1/SvEZ0CcBCwrBCatdd'
          'D7802RGBk+o2wSINix6JBlY0RuNk3Mfap5Ch0iq8CQ/Vabx7R/nmoyuIxrvHAaz7L'
          'iC5VaBT8/082fhUGISG4xWAqIoP8EpIsklW9Eell4bs2auYg3FpjVz0oJWve0mZWn'
          'puYUPOehC4rzQRS7q+qe6zeVNXgb9IvFbROCYrpdlpaOQ506I50r3/OvWOo8rpAFL'
          'vog5BibxDQtWBVjCcejKuVDmrUr2nmQNhmoD/9CC8mD9MZJF01s1Cuggf80GdnJAPd'
          'LN6VCNYQGNe1TK3JsQSwu47RCbsP3h8EeMHeQhYo8+2D4T936FnO+IKmz4VjgsUVm'
          'gjdW3yX3jhwJHwj9L1BNDEaIMwSgtt95ariurcMgfoD3C3OxDj04dw4SRWX7UHOlo'
          '53VggmE6lywRVFg==';
      expect(encrypted, expectedCiphertext);
    });
  });

  group('zeroPadToBlockSize boundaries', () {
    test('handles 0, 15, 16, and 17 byte inputs', () {
      final input0 = _fixtureBytes(0);
      final padded0 = zeroPadToBlockSize(input0);
      expect(padded0, isEmpty);

      final input15 = _fixtureBytes(15);
      final padded15 = zeroPadToBlockSize(input15);
      expect(padded15.length, 16);
      expect(padded15.sublist(0, 15), orderedEquals(input15));
      expect(padded15[15], 0);

      final input16 = _fixtureBytes(16);
      final padded16 = zeroPadToBlockSize(input16);
      expect(padded16.length, 16);
      expect(padded16, orderedEquals(input16));

      final input17 = _fixtureBytes(17);
      final padded17 = zeroPadToBlockSize(input17);
      expect(padded17.length, 32);
      expect(padded17.sublist(0, 17), orderedEquals(input17));
      expect(padded17.sublist(17), everyElement(0));
    });
  });
}

Uint8List _fixtureBytes(int length) {
  return Uint8List.fromList(
    List<int>.generate(length, (int index) => index + 1),
  );
}
