import 'dart:convert';
import 'dart:math';

enum DeviceProtocol { appPortal, webPortal }

/// Configuration for the APK's first (account) login request.
///
/// The official client sends this request to `/wocloud_v2/appUser/appLogin.bin`
/// before it starts the captive-portal authentication.  `serviceType` is the
/// selected account/service category (the APK defaults to 1, GiWiFi user),
/// while `gatewayId` is the optional opaque gateway identifier carried in the
/// outer request envelope.  `gatewayAddress` is the local gateway IPv4 sent in
/// the encrypted inner `gwAddress` field; it is kept separate from
/// `gatewayId` because the APK treats them as two different values.
class AppAccountLoginOptions {
  const AppAccountLoginOptions({
    this.enabled = true,
    this.serviceType = 1,
    this.fallbackServiceTypes = const <int>[],
    this.gatewayId = '',
    this.gatewayAddress = '',
    this.token = '',
    this.version = kGiWifiApkVersion,
  });

  final bool enabled;
  final int serviceType;
  final List<int> fallbackServiceTypes;
  final String gatewayId;
  final String gatewayAddress;
  final String token;
  final String version;

  /// Ordered service types to try.  A fallback is useful for deployments that
  /// expose a carrier-specific account category while retaining the APK's
  /// normal service type 1 as the first attempt.
  List<int> get serviceTypes {
    final values = <int>[serviceType, ...fallbackServiceTypes];
    final unique = <int>[];
    for (final value in values) {
      if (value >= 1 && value <= 4 && !unique.contains(value)) {
        unique.add(value);
      }
    }
    return unique.isEmpty ? <int>[1] : unique;
  }
}

/// Plaintext model for one APK account-layer request.
///
/// `toJson` applies the APK's AES-128-ECB/PKCS5 field encryption to the same
/// fields as `EncryptUtil.getEncrypt`; `apMac` intentionally remains a plain
/// empty string, matching the decompiled request builder.
class AppAccountLoginRequest {
  const AppAccountLoginRequest({
    required this.serviceType,
    required this.phone,
    required this.staticPassword,
    required this.ip,
    required this.apMac,
    required this.gatewayAddress,
    required this.staType,
    required this.staModel,
    required this.token,
    required this.version,
    required this.mac,
    required this.gatewayId,
  });

  final int serviceType;
  final String phone;
  final String staticPassword;
  final String ip;
  final String apMac;
  final String gatewayAddress;
  final String staType;
  final String staModel;
  final String token;
  final String version;
  final String mac;
  final String gatewayId;

  Map<String, Object> toJson({required String Function(String) encrypt}) {
    final inner = <String, Object>{
      'service_type': encrypt(serviceType.toString()),
      'phone': encrypt(phone),
      'staticPassword': encrypt(staticPassword),
      'ip': encrypt(ip),
      'apMac': apMac,
      'gwAddress': encrypt(gatewayAddress),
      'staType': encrypt(staType),
      'staModel': encrypt(staModel),
    };
    return <String, Object>{
      'token': encrypt(token),
      'version': version,
      'mac': encrypt(mac),
      'gatewayId': encrypt(gatewayId),
      'data': _jsonEncode(inner),
    };
  }

  static String _jsonEncode(Map<String, Object> value) {
    // The APK puts a JSON *string* in the outer `data` member.  Use Dart's
    // encoder rather than hand-assembling JSON so credentials, gateway names,
    // and device model strings containing quotes, backslashes, or non-ASCII
    // characters are escaped exactly once.
    return jsonEncode(value);
  }
}

const String kGiWifiApkVersion = '2.4.1.21';

enum DeviceProfile {
  android(
    label: 'Android',
    protocol: DeviceProtocol.appPortal,
    userAgent:
        'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
    loginPath: '/gportal/web/login?has_reload=1&pagetype=login&logintype=1',
    btype: '1',
    staType: 'phone',
    staModel: 'Google,Pixel 9,35,15',
  ),
  apad(
    label: 'APad',
    protocol: DeviceProtocol.appPortal,
    userAgent:
        'Mozilla/5.0 (Linux; Android 15; Pixel Tablet) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/131.0.0.0 Safari/537.36',
    loginPath: '/gportal/web/login?has_reload=1&pagetype=login&logintype=1',
    btype: '2',
    staType: 'pad',
    // Official APK success capture on the rooted tablet. This value is the
    // exact Build.MANUFACTURER,MODEL,SDK,RELEASE string emitted on the wire.
    staModel: 'samsung,SM-T870,34,14',
  ),
  windows(
    label: 'Windows',
    protocol: DeviceProtocol.webPortal,
    userAgent:
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36',
    deviceMode: 'Windows NT 10.0',
    deviceType: '1',
    deviceOsType: '3',
    isMobile: '0',
    loginPath: '/gportal/web/login?has_reload=1',
  );

  const DeviceProfile({
    required this.label,
    required this.protocol,
    required this.userAgent,
    required this.loginPath,
    this.deviceMode = '',
    this.deviceType = '',
    this.deviceOsType = '',
    this.isMobile = '',
    this.btype = '',
    this.staType = '',
    this.staModel = '',
  });

  final String label;
  final DeviceProtocol protocol;
  final String userAgent;
  final String loginPath;
  final String deviceMode;
  final String deviceType;
  final String deviceOsType;
  final String isMobile;
  final String btype;
  final String staType;
  final String staModel;

  Uri buildLoginUri(Uri baseUri) => baseUri.resolve(loginPath);
}

final RegExp _giWifiAppUuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{15}$',
  caseSensitive: false,
);

bool isGiWifiAppUuid(String value) => _giWifiAppUuidPattern.hasMatch(value);

String generateGiWifiAppUuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  final uuid =
      '${hex.substring(0, 8)}-'
      '${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-'
      '${hex.substring(20)}';

  return '${uuid.substring(0, 23)}${uuid.substring(24)}';
}

enum LoginOutcome { success, failure, cancelled }

class LoginSession {
  const LoginSession({
    required this.profile,
    required this.ip,
    required this.connectedAt,
    required this.baseUrl,
    this.logoutUrl,
    this.resolvedPortalOrigin,
  });

  final DeviceProfile profile;
  final String ip;
  final DateTime connectedAt;
  final String baseUrl;
  final Uri? logoutUrl;

  /// Canonical App Portal origin learned from the captive redirect.
  ///
  /// APK clients cache this origin and reuse it when the fixed connectivity
  /// probe returns a normal HTTP 200 after authentication.  Desktop callers
  /// may persist it as the next `baseUrl`; Web Portal sessions leave it null.
  final String? resolvedPortalOrigin;
}

class LoginResult {
  const LoginResult({required this.outcome, required this.info, this.session});

  final LoginOutcome outcome;
  final String info;
  final LoginSession? session;
}
