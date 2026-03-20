enum DeviceProfile {
  windows(
    label: 'Windows',
    userAgent:
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36',
    deviceMode: 'Windows NT 10.0',
    deviceType: '1',
    deviceOsType: '3',
    isMobile: '0',
    loginPath: '/gportal/web/login?has_reload=1',
  ),
  iphone(
    label: 'iPhone',
    userAgent:
        'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 '
        'Mobile/15E148 Safari/604.1',
    deviceMode: 'iPhone',
    deviceType: '2',
    deviceOsType: '2',
    isMobile: '1',
    loginPath: '/gportal/web/login?has_reload=1&pagetype=login&logintype=1',
  ),
  ipad(
    label: 'iPad',
    userAgent:
        'Mozilla/5.0 (iPad; CPU OS 18_5 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 '
        'Mobile/15E148 Safari/604.1',
    deviceMode: 'iPad',
    deviceType: '3',
    deviceOsType: '2',
    isMobile: '1',
    loginPath: '/gportal/web/login?has_reload=1&pagetype=login&logintype=1',
  );

  const DeviceProfile({
    required this.label,
    required this.userAgent,
    required this.deviceMode,
    required this.deviceType,
    required this.deviceOsType,
    required this.isMobile,
    required this.loginPath,
  });

  final String label;
  final String userAgent;
  final String deviceMode;
  final String deviceType;
  final String deviceOsType;
  final String isMobile;
  final String loginPath;

  Uri buildLoginUri(Uri baseUri) => baseUri.resolve(loginPath);
}

enum LoginOutcome { success, failure, cancelled }

class LoginSession {
  const LoginSession({
    required this.profile,
    required this.ip,
    required this.connectedAt,
    required this.baseUrl,
    this.logoutUrl,
  });

  final DeviceProfile profile;
  final String ip;
  final DateTime connectedAt;
  final String baseUrl;
  final Uri? logoutUrl;
}

class LoginResult {
  const LoginResult({required this.outcome, required this.info, this.session});

  final LoginOutcome outcome;
  final String info;
  final LoginSession? session;
}
