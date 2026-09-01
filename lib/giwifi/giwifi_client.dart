import 'dart:convert';
import 'dart:collection';
import 'dart:typed_data';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';

import 'app_network_identity.dart';
import 'giwifi_models.dart';

typedef LoginLogSink = void Function(String entry);
typedef BindConflictHandler = Future<bool> Function(String message);

const List<String> kPortalFieldOrder = <String>[
  'sign',
  'sta_vlan',
  'sta_port',
  'sta_ip',
  'nas_ip',
  'nas_name',
  'last_url',
  'request_ip',
  'device_mode',
  'device_type',
  'device_os_type',
  'is_mobile',
  'iv',
  'login_type',
  'account_type',
  'user_account',
  'user_password',
];

final Uint8List _aesKeyBytes = Uint8List.fromList(
  utf8.encode('1234567887654321'),
);

const String _appPortalAesKey = '5447c08b53e8dac4';
const String _appPortalSignSecret = '5447c08b53e8dac47f81269f98cfeada';
const String _defaultAppPortalProbeUrl = 'http://115.159.209.137';
const String _appPortalFallbackHost = 'as.gwifi.com.cn';
const String _appPortalApiUserAgent = 'okhttp/3.8.0';
const String _appPortalDiscoveryUserAgent =
    'Mozilla/5.0 (Linux; U; Android 11; zh-cn; '
    'M2011K2C Build/RKQ1.200928.002) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Version/4.0 Chrome/79.0.3945.147 '
    'Mobile Safari/537.36 XiaoMi/MiuiBrowser/14.7.10';
const List<String> _appNasNameKeys = <String>[
  'wlanacname',
  'nasName',
  'nas_name',
];
const List<String> _appUserMacKeys = <String>[
  'userMac',
  'user_mac',
  'staMac',
  'sta_mac',
  'wlanusermac',
  'wlanUserMac',
  'clientMac',
  'client_mac',
];
const Map<String, String> _appPortalDiscoveryHeaders = <String, String>{
  'Connection': 'keep-alive',
  'Upgrade-Insecure-Requests': '1',
  'User-Agent': _appPortalDiscoveryUserAgent,
  'Accept':
      'text/html,application/xhtml+xml,application/xml;q=0.9,'
      'image/webp,image/apng,*/*;q=0.8,'
      'application/signed-exchange;v=b3;q=0.9',
  'x-miorigin': 's',
  'Accept-Encoding': 'gzip, deflate',
  'Accept-Language': 'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7',
};

final Uint8List _appPortalAesKeyBytes = Uint8List.fromList(
  utf8.encode(_appPortalAesKey),
);

int _systemEpochSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

class GiWifiClient {
  GiWifiClient({
    http.Client Function()? clientFactory,
    int Function()? epochSeconds,
    Future<void> Function(Duration duration)? delay,
    AppNetworkIdentityResolver? appNetworkIdentityResolver,
    String appPortalProbeUrl = _defaultAppPortalProbeUrl,
    AppAccountLoginOptions appAccountOptions = const AppAccountLoginOptions(),
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _epochSeconds = epochSeconds ?? _systemEpochSeconds,
       _delay =
           delay ?? ((Duration duration) => Future<void>.delayed(duration)),
       _appNetworkIdentityResolver =
           appNetworkIdentityResolver ?? resolveAppNetworkIdentity,
       _appPortalProbeUrl = appPortalProbeUrl,
       _appAccountOptions = appAccountOptions,
       _runtimeAppUuid = generateGiWifiAppUuid();

  final http.Client Function() _clientFactory;
  final int Function() _epochSeconds;
  final Future<void> Function(Duration duration) _delay;
  final AppNetworkIdentityResolver _appNetworkIdentityResolver;
  final String _appPortalProbeUrl;
  final AppAccountLoginOptions _appAccountOptions;
  final String _runtimeAppUuid;

  // The APK keeps the last discovered Portal host in its process cache.  A
  // captive gateway commonly answers the probe with HTTP 200 after login;
  // in that state there is no redirect to rediscover the canonical host.  We
  // retain the last redirect for subsequent logins in this client instance,
  // while still preferring a fresh redirect or an explicit rebind context.
  Uri? _lastAppPortalUri;

  Future<LoginResult> login({
    required String baseUrl,
    required DeviceProfile profile,
    required String username,
    required String password,
    required BindConflictHandler onBindConflict,
    String appUuid = '',
    AppAccountLoginOptions? appAccountOptions,
    LoginLogSink? onLog,
  }) async {
    if (profile.protocol == DeviceProtocol.appPortal) {
      return _loginWithAppPortal(
        baseUrl: baseUrl,
        profile: profile,
        username: username,
        password: password,
        appUuid: appUuid.trim().isEmpty ? _runtimeAppUuid : appUuid.trim(),
        appAccountOptions: appAccountOptions ?? _appAccountOptions,
        onBindConflict: onBindConflict,
        onLog: onLog,
      );
    }

    return _loginWithWebPortal(
      baseUrl: baseUrl,
      profile: profile,
      username: username,
      password: password,
      onBindConflict: onBindConflict,
      onLog: onLog,
    );
  }

  Future<LoginResult> _loginWithWebPortal({
    required String baseUrl,
    required DeviceProfile profile,
    required String username,
    required String password,
    required BindConflictHandler onBindConflict,
    LoginLogSink? onLog,
  }) async {
    final client = _clientFactory();
    final baseUri = Uri.parse(baseUrl);

    void logInfo(String message) => onLog?.call('[INFO] $message');
    void logWarn(String message) => onLog?.call('[WARN] $message');

    try {
      logInfo('获取登录页');
      final loginContext = await _fetchLoginContext(
        client: client,
        baseUri: baseUri,
        profile: profile,
      );

      logInfo('解析 iv=${loginContext.iv}');
      logInfo('终端: ${profile.label}');

      final plaintext = serializePortalFields(
        _buildPayloadFields(
          pageFields: loginContext.pageFields,
          profile: profile,
          username: username,
          password: password,
        ),
      );
      final encryptedPayload = encryptPortalPayload(
        plaintext: plaintext,
        iv: loginContext.iv,
      );

      logInfo('发送登录请求');
      var loginResponse = await _postLoginAction(
        client: client,
        baseUri: baseUri,
        loginUri: loginContext.loginUri,
        sessionId: loginContext.sessionId,
        profile: profile,
        encryptedPayload: encryptedPayload,
        iv: loginContext.iv,
      );

      if (loginResponse.isSuccess) {
        logInfo('登录成功');
        return LoginResult(
          outcome: LoginOutcome.success,
          info: loginResponse.info,
          session: LoginSession(
            profile: profile,
            ip: _resolveIp(loginContext.pageFields),
            connectedAt: DateTime.now(),
            baseUrl: baseUrl,
            logoutUrl: loginResponse.logoutUrl,
          ),
        );
      }

      if (loginResponse.requiresBind) {
        logWarn('检测到设备冲突，需要换绑');
        final shouldContinue = await onBindConflict(loginResponse.info);
        if (!shouldContinue) {
          logInfo('用户取消换绑');
          return const LoginResult(
            outcome: LoginOutcome.cancelled,
            info: '已取消换绑',
          );
        }

        logInfo('发送 bindSta 请求');
        final bindResponse = await _postBindSta(
          client: client,
          baseUri: baseUri,
          bindPath: loginResponse.bindPath!,
          loginUri: loginContext.loginUri,
          sessionId: loginContext.sessionId,
          profile: profile,
        );

        if (!bindResponse.isSuccess) {
          logWarn('换绑失败');
          return LoginResult(
            outcome: LoginOutcome.failure,
            info: bindResponse.info,
          );
        }

        logInfo('换绑成功，开始重试登录');
        for (var attempt = 1; attempt <= 3; attempt++) {
          if (attempt > 1) {
            await _delay(const Duration(seconds: 2));
          }

          logInfo('重试登录，第 $attempt 次');
          loginResponse = await _postLoginAction(
            client: client,
            baseUri: baseUri,
            loginUri: loginContext.loginUri,
            sessionId: loginContext.sessionId,
            profile: profile,
            encryptedPayload: encryptedPayload,
            iv: loginContext.iv,
          );

          if (loginResponse.isSuccess) {
            logInfo('登录成功');
            return LoginResult(
              outcome: LoginOutcome.success,
              info: loginResponse.info,
              session: LoginSession(
                profile: profile,
                ip: _resolveIp(loginContext.pageFields),
                connectedAt: DateTime.now(),
                baseUrl: baseUrl,
                logoutUrl: loginResponse.logoutUrl,
              ),
            );
          }

          logWarn(
            '重试未成功'
            '${loginResponse.resultCode == null ? '' : '，resultCode=${loginResponse.resultCode}'}',
          );
        }
      }

      logWarn('登录失败');
      return LoginResult(
        outcome: LoginOutcome.failure,
        info: loginResponse.info,
      );
    } finally {
      client.close();
    }
  }

  Future<LoginResult> _loginWithAppPortal({
    required String baseUrl,
    required DeviceProfile profile,
    required String username,
    required String password,
    required String appUuid,
    required AppAccountLoginOptions appAccountOptions,
    required BindConflictHandler onBindConflict,
    LoginLogSink? onLog,
  }) async {
    final client = _clientFactory();
    final baseUri = Uri.parse(baseUrl);

    void logInfo(String message) => onLog?.call('[INFO] $message');
    void logWarn(String message) => onLog?.call('[WARN] $message');

    try {
      logInfo('获取 Portal 网络参数');
      var context = await _fetchAppPortalContext(
        client: client,
        baseUri: baseUri,
        profile: profile,
      );

      logInfo('终端: ${profile.label}');
      logInfo(
        'Portal: ${context.portalUri.origin}，'
        'userIp=${context.userIp}，'
        'nasName=${context.nasName.isEmpty ? "未返回" : context.nasName}，'
        'userMac=${context.userMac.isEmpty ? "等待网关识别" : "已获取"}'
        '${context.interfaceName.isEmpty ? "" : "，interface=${context.interfaceName}"}',
      );

      if (appAccountOptions.enabled) {
        logInfo('发送 APK App 账号认证请求');
        final accountResponse = await _postAppAccountLogin(
          client: client,
          profile: profile,
          context: context,
          username: username,
          password: password,
          options: appAccountOptions,
        );
        if (!accountResponse.isSuccess) {
          logWarn(
            'App 账号认证失败: '
            'resultCode=${accountResponse.resultCode ?? "null"}，'
            '${accountResponse.displayInfo}',
          );
          return LoginResult(
            outcome: LoginOutcome.failure,
            info: accountResponse.displayInfo,
          );
        }
        logInfo('App 账号认证成功，继续 Portal 网络准入认证');
      } else {
        logInfo('已关闭 APK App 账号认证层（仅用于协议测试）');
      }

      logInfo('查询 App Portal 认证状态');
      final stateResponse = await _queryAppAuthState(
        client: client,
        context: context,
        username: username,
      );

      final authState = stateResponse.dataInt('authState');
      logInfo(
        '认证状态响应: '
        'resultCode=${stateResponse.errorCode ?? "null"}，'
        'authState=${authState ?? "null"}',
      );

      if (!stateResponse.isSuccess) {
        logWarn('认证状态查询失败: ${stateResponse.displayInfo}');
        return LoginResult(
          outcome: LoginOutcome.failure,
          info: stateResponse.displayInfo,
        );
      }

      context = context.copyWith(
        nasName: _firstNonEmpty(<String?>[
          context.nasName,
          _firstAppDataValue(stateResponse, _appNasNameKeys),
        ]),
        userMac: _firstUsableMac(<String?>[
          _firstAppDataValue(stateResponse, _appUserMacKeys),
          context.userMac,
        ]),
      );

      logInfo(
        'Portal 识别参数: '
        'nasName=${context.nasName.isEmpty ? "未返回" : context.nasName}，'
        'userMac=${context.userMac.isEmpty ? "未返回" : "已获取"}',
      );

      if (_isAuthenticatedAppState(authState)) {
        logInfo('当前终端已处于认证状态');
        return _appAuthStateSuccess(
          response: stateResponse,
          authState: authState!,
          profile: profile,
          context: context,
          baseUrl: baseUrl,
        );
      }

      if (!isUsableMacAddress(context.userMac)) {
        logWarn('未获取当前 Wi-Fi 接口 MAC，按照 APK 流程继续由网关识别');
      }

      logInfo('发送 App Portal 登录请求');
      var loginResponse = await _postAppAuthLogin(
        client: client,
        profile: profile,
        context: context,
        appUuid: appUuid,
        username: username,
        password: password,
      );

      if (loginResponse.isSuccess) {
        logInfo('登录成功');
        return _appLoginSuccess(
          response: loginResponse,
          profile: profile,
          context: context,
          baseUrl: baseUrl,
        );
      }

      if (loginResponse.requiresBind) {
        logWarn('检测到设备冲突，需要换绑');
        final shouldContinue = await onBindConflict(loginResponse.displayInfo);
        if (!shouldContinue) {
          logInfo('用户取消换绑');
          return const LoginResult(
            outcome: LoginOutcome.cancelled,
            info: '已取消换绑',
          );
        }

        logInfo('发送 App Portal reBindMac 请求');
        final bindResponse = await _postAppRebindMac(
          client: client,
          profile: profile,
          context: context,
          appUuid: appUuid,
          username: username,
          password: password,
        );

        if (!bindResponse.isSuccess) {
          logWarn('换绑失败');
          return LoginResult(
            outcome: LoginOutcome.failure,
            info: bindResponse.displayInfo,
          );
        }

        logInfo('换绑成功，等待网关同步');
        await _delay(const Duration(seconds: 4));

        try {
          final refreshedContext = await _fetchAppPortalContext(
            client: client,
            baseUri: baseUri,
            profile: profile,
            fallbackPortalUri: context.portalUri,
          );
          context = refreshedContext.copyWith(
            nasName: _firstNonEmpty(<String?>[
              refreshedContext.nasName,
              context.nasName,
            ]),
            userMac: _firstUsableMac(<String?>[
              refreshedContext.userMac,
              context.userMac,
            ]),
            staModel: _firstNonEmpty(<String?>[
              refreshedContext.staModel,
              context.staModel,
            ]),
            gatewayIp: _firstNonEmpty(<String?>[
              refreshedContext.gatewayIp,
              context.gatewayIp,
            ]),
          );
        } on Object catch (error) {
          logWarn('换绑后的 Portal 网络参数重新探测失败，沿用现有参数: $error');
        }

        final refreshedStateResponse = await _queryAppAuthState(
          client: client,
          context: context,
          username: username,
        );
        if (refreshedStateResponse.isSuccess) {
          context = context.copyWith(
            nasName: _firstNonEmpty(<String?>[
              context.nasName,
              _firstAppDataValue(refreshedStateResponse, _appNasNameKeys),
            ]),
            userMac: _firstUsableMac(<String?>[
              _firstAppDataValue(refreshedStateResponse, _appUserMacKeys),
              context.userMac,
            ]),
          );

          final refreshedAuthState = refreshedStateResponse.dataInt(
            'authState',
          );
          if (_isAuthenticatedAppState(refreshedAuthState)) {
            logInfo('换绑后终端已处于认证状态');
            return _appAuthStateSuccess(
              response: refreshedStateResponse,
              authState: refreshedAuthState!,
              profile: profile,
              context: context,
              baseUrl: baseUrl,
            );
          }
        } else {
          logWarn('换绑后的认证状态刷新失败，沿用现有网络参数');
        }

        if (!isUsableMacAddress(context.userMac)) {
          logWarn('换绑后仍未获取当前 Wi-Fi 接口 MAC，按照 APK 流程继续提交');
        }

        logInfo('换绑后重试登录');
        loginResponse = await _postAppAuthLogin(
          client: client,
          profile: profile,
          context: context,
          appUuid: appUuid,
          username: username,
          password: password,
        );

        if (loginResponse.isSuccess) {
          logInfo('登录成功');
          return _appLoginSuccess(
            response: loginResponse,
            profile: profile,
            context: context,
            baseUrl: baseUrl,
          );
        }
        logWarn(
          '换绑后登录未成功'
          '${loginResponse.errorCode == null ? '' : '，resultCode=${loginResponse.errorCode}'}',
        );
      }

      logWarn(
        '登录失败: '
        'resultCode=${loginResponse.errorCode ?? "null"}，'
        '${loginResponse.displayInfo}',
      );
      return LoginResult(
        outcome: LoginOutcome.failure,
        info: loginResponse.displayInfo,
      );
    } finally {
      client.close();
    }
  }

  Future<_AppPortalResponse> _queryAppAuthState({
    required http.Client client,
    required _AppPortalContext context,
    required String username,
  }) async {
    Object? lastError;
    StackTrace? lastStackTrace;
    final fields = <String, String>{
      'timestamp': _epochSeconds().toString(),
      'userIp': context.userIp,
      'userName': username,
    };

    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        return await _postAppPortalRequest(
          client: client,
          portalUri: context.portalUri,
          path: '/gportal/app/queryAuthState',
          fields: fields,
        ).timeout(const Duration(seconds: 2));
      } on Object catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
      }
    }

    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  Future<_AppAccountLoginResponse> _postAppAccountLogin({
    required http.Client client,
    required DeviceProfile profile,
    required _AppPortalContext context,
    required String username,
    required String password,
    required AppAccountLoginOptions options,
  }) async {
    final accountUri = _buildAppAccountLoginUri(context.portalUri);
    Object? lastResponse;

    for (final serviceType in options.serviceTypes) {
      final request = AppAccountLoginRequest(
        serviceType: serviceType,
        phone: username,
        staticPassword: password,
        ip: context.userIp,
        apMac: '',
        gatewayAddress: _firstNonEmpty(<String?>[
          options.gatewayAddress,
          context.gatewayIp,
        ]),
        staType: profile.staType,
        staModel: context.staModel.isEmpty
            ? profile.staModel
            : context.staModel,
        token: options.token,
        version: options.version,
        mac: context.userMac,
        gatewayId: options.gatewayId,
      );
      final response = await client.post(
        accountUri,
        headers: const <String, String>{
          'Content-Type': 'text/plain;charset=utf-8',
        },
        body: jsonEncode(request.toJson(encrypt: encryptAppPortalPayload)),
      );

      _ensureOk(response, '发送 App 账号认证请求');
      final parsed = _AppAccountLoginResponse.fromJsonBody(response.body);
      lastResponse = parsed;
      if (parsed.isSuccess || serviceType == options.serviceTypes.last) {
        return parsed;
      }
    }

    // `serviceTypes` always contains at least one value.  Keep the guard for
    // future changes to the options model so an invalid empty sequence fails
    // with a useful response rather than a null assertion.
    if (lastResponse is _AppAccountLoginResponse) {
      return lastResponse;
    }
    return const _AppAccountLoginResponse(
      resultCode: null,
      resultMsg: 'App 账号认证没有可用服务类型',
      info: '',
    );
  }

  Uri _buildAppAccountLoginUri(Uri portalUri) {
    if (portalUri.host.isEmpty) {
      throw const FormatException('App 账号认证缺少 Portal 主机');
    }
    // C3989i.m22802A0() always targets the station cloud port 8080 and does
    // not reuse the captive Portal's HTTP port.
    return Uri(
      scheme: 'http',
      host: portalUri.host,
      port: 8080,
      path: '/wocloud_v2/appUser/appLogin.bin',
    );
  }

  /*
   * Android/APad deliberately stop here before the Web Portal implementation.
   * The remaining methods below are shared result helpers or the Windows-only
   * Web Portal branch.
   */

  LoginResult _appLoginSuccess({
    required _AppPortalResponse response,
    required DeviceProfile profile,
    required _AppPortalContext context,
    required String baseUrl,
  }) {
    return LoginResult(
      outcome: LoginOutcome.success,
      info: response.displayInfo,
      session: LoginSession(
        profile: profile,
        ip: context.userIp,
        connectedAt: DateTime.now(),
        baseUrl: baseUrl,
        resolvedPortalOrigin: context.portalUri.origin,
      ),
    );
  }

  LoginResult _appAuthStateSuccess({
    required _AppPortalResponse response,
    required int authState,
    required DeviceProfile profile,
    required _AppPortalContext context,
    required String baseUrl,
  }) {
    final tips = response.dataString('tips')?.trim() ?? '';
    final info = tips.isNotEmpty
        ? tips
        : authState == 200
        ? '认证已建立，但当前外网状态异常'
        : '当前终端已认证在线';

    return LoginResult(
      outcome: LoginOutcome.success,
      info: info,
      session: LoginSession(
        profile: profile,
        ip: context.userIp,
        connectedAt: DateTime.now(),
        baseUrl: baseUrl,
        resolvedPortalOrigin: context.portalUri.origin,
      ),
    );
  }

  Future<_AppPortalContext> _fetchAppPortalContext({
    required http.Client client,
    required Uri baseUri,
    required DeviceProfile profile,
    Uri? fallbackPortalUri,
  }) async {
    final discoveredPortalUri = await _discoverAppPortalUri(client);
    final configuredPortalUri = _isAppPortalLoginUri(baseUri)
        ? baseUri
        : profile.buildLoginUri(baseUri);
    if (discoveredPortalUri != null) {
      _lastAppPortalUri = _appPortalTransportUri(discoveredPortalUri);
    } else if (fallbackPortalUri != null) {
      // A rebind may pass the previous Portal origin as a fallback while the
      // fresh captive probe is temporarily unavailable.  Cache that origin
      // only when discovery did not produce a newer one; otherwise a stale
      // fallback must not overwrite the APK-style process cache.
      _lastAppPortalUri = _appPortalTransportUri(fallbackPortalUri);
    }
    final portalUri = _appPortalTransportUri(
      discoveredPortalUri ??
          fallbackPortalUri ??
          _lastAppPortalUri ??
          configuredPortalUri,
    );
    final identity = await _appNetworkIdentityResolver(portalUri);

    if (!isUsableIpv4Address(identity.userIp)) {
      throw const FormatException('未获取当前网络接口 IPv4，已停止 App Portal 认证');
    }

    return _AppPortalContext(
      portalUri: portalUri,
      userIp: identity.userIp.trim(),
      nasName: _firstMapValue(portalUri.queryParameters, const <String>[
        'wlanacname',
      ]),
      userMac: _firstUsableMac(<String?>[identity.userMac]),
      interfaceName: identity.interfaceName,
      staModel: identity.staModel,
      gatewayIp: isUsableIpv4Address(identity.gatewayIp)
          ? identity.gatewayIp
          : '',
    );
  }

  Future<Uri?> _discoverAppPortalUri(http.Client client) async {
    final rawProbeUrl = _appPortalProbeUrl.trim();
    if (rawProbeUrl.isEmpty) {
      return null;
    }

    final probeUri = Uri.tryParse(rawProbeUrl);
    if (probeUri == null || !probeUri.hasScheme || probeUri.host.isEmpty) {
      return null;
    }

    try {
      final request = http.Request('GET', probeUri)
        ..followRedirects = false
        ..headers.addAll(_appPortalDiscoveryHeaders);
      final streamedResponse = await client
          .send(request)
          .timeout(const Duration(seconds: 2));
      final response = await http.Response.fromStream(
        streamedResponse,
      ).timeout(const Duration(seconds: 3));

      // Captive gateways are not consistent about the redirect code.  The
      // APK/OkHttp flow follows all ordinary HTTP redirects, while some
      // GiWiFi nodes currently return 301 (and a few deployments return
      // 308) for the first probe.  Keep redirects disabled so we can inspect
      // the Portal URI, but accept the complete permanent/temporary set.
      if (<int>{301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers['location']?.trim() ?? '';
        return _parseAppPortalUri(location, relativeTo: probeUri);
      }

      if (response.statusCode == 200) {
        // This is the exact empty-success marker handled by the APK.  It is
        // returned after a station is already authenticated, so the fixed
        // probe no longer redirects to the captive Portal.  The APK then
        // resolves its canonical fallback host and continues with App Portal
        // state/auth requests; mirror that branch instead of falling back to
        // the legacy login.gwifi.com.cn alias.
        final normalizedBody = response.body.trim();
        if (normalizedBody == r'{"resultCode":0,"data":"\"\""}' &&
            _lastAppPortalUri == null) {
          return Uri(
            scheme: 'http',
            host: _appPortalFallbackHost,
            path: '/gportal/web/login',
          );
        }
        return _extractAppPortalUriFromBody(response.body, probeUri);
      }
    } on Object {
      return null;
    }

    return null;
  }

  Uri? _extractAppPortalUriFromBody(String body, Uri probeUri) {
    final normalizedBody = body
        .replaceAll(r'\/', '/')
        .replaceAll('&amp;', '&')
        .replaceAll('&#38;', '&');
    final matches = RegExp(
      r'''(?:https?|ftp)://[^\s"'<>]+''',
      caseSensitive: false,
    ).allMatches(normalizedBody);

    for (final match in matches) {
      final portalUri = _parseAppPortalUri(
        match.group(0) ?? '',
        relativeTo: probeUri,
      );
      if (portalUri != null) {
        return portalUri;
      }
    }
    return null;
  }

  Uri? _parseAppPortalUri(String value, {required Uri relativeTo}) {
    final normalized = value
        .trim()
        .replaceAll('&amp;', '&')
        .replaceAll('&#38;', '&');
    if (normalized.isEmpty) {
      return null;
    }

    final parsed = Uri.tryParse(normalized);
    if (parsed == null) {
      return null;
    }
    final resolved = parsed.hasScheme ? parsed : relativeTo.resolveUri(parsed);
    return _isAppPortalLoginUri(resolved) ? resolved : null;
  }

  Future<_AppPortalResponse> _postAppAuthLogin({
    required http.Client client,
    required DeviceProfile profile,
    required _AppPortalContext context,
    required String appUuid,
    required String username,
    required String password,
  }) {
    return _postAppPortalRequest(
      client: client,
      portalUri: context.portalUri,
      path: '/gportal/app/authLogin',
      passwordField: 'passwd',
      fields: <String, String>{
        'appUuid': appUuid,
        'userIp': context.userIp,
        'nasName': _appPortalNasNameForWire(context.nasName),
        'ssid': '',
        'nasIp': '',
        'userMac': context.userMac,
        'vlan': '1',
        'apMac': '',
        'userFirstUrl': '',
        'userName': username,
        'passwd': password,
        'btype': profile.btype,
        'staType': profile.staType,
        'staModel': context.staModel.isEmpty
            ? profile.staModel
            : context.staModel,
        'timestamp': _epochSeconds().toString(),
      },
    );
  }

  Future<_AppPortalResponse> _postAppRebindMac({
    required http.Client client,
    required DeviceProfile profile,
    required _AppPortalContext context,
    required String appUuid,
    required String username,
    required String password,
  }) {
    return _postAppPortalRequest(
      client: client,
      portalUri: context.portalUri,
      path: '/gportal/app/reBindMac',
      passwordField: 'passwd',
      fields: <String, String>{
        'appUuid': appUuid,
        'nasName': _appPortalNasNameForWire(context.nasName),
        'userMac': context.userMac,
        'userIp': context.userIp,
        'btype': profile.btype,
        'staType': profile.staType,
        'staModel': context.staModel.isEmpty
            ? profile.staModel
            : context.staModel,
        'userName': username,
        'passwd': password,
        'timestamp': _epochSeconds().toString(),
      },
    );
  }

  Future<_AppPortalResponse> _postAppPortalRequest({
    required http.Client client,
    required Uri portalUri,
    required String path,
    required Map<String, String> fields,
    String? passwordField,
  }) async {
    final plaintext = buildAppPortalSignedPayload(
      fields,
      passwordField: passwordField,
    );
    final response = await client.post(
      portalUri.resolve(path),
      headers: <String, String>{
        'Content-Type': 'application/x-www-form-urlencoded',
        'Connection': 'Keep-Alive',
        'User-Agent': _appPortalApiUserAgent,
      },
      body: <String, String>{'data': encodeAppPortalData(plaintext)},
    );

    _ensureOk(response, '请求 $path');
    return _AppPortalResponse.fromJsonBody(response.body);
  }

  Future<_LoginPageContext> _fetchLoginContext({
    required http.Client client,
    required Uri baseUri,
    required DeviceProfile profile,
  }) async {
    final loginUri = profile.buildLoginUri(baseUri);
    final response = await client.get(
      loginUri,
      headers: <String, String>{'User-Agent': profile.userAgent},
    );

    _ensureOk(response, '获取登录页');

    final sessionId = _extractPhpSessionId(response.headers);
    final fields = _parseHiddenFields(response.body);
    _validatePageFields(fields);

    return _LoginPageContext(
      loginUri: loginUri,
      sessionId: sessionId,
      pageFields: fields,
    );
  }

  Map<String, String> _buildPayloadFields({
    required Map<String, String> pageFields,
    required DeviceProfile profile,
    required String username,
    required String password,
  }) {
    return <String, String>{
      'sign': pageFields['sign'] ?? '',
      'sta_vlan': pageFields['sta_vlan'] ?? '',
      'sta_port': pageFields['sta_port'] ?? '',
      'sta_ip': pageFields['sta_ip'] ?? '',
      'nas_ip': pageFields['nas_ip'] ?? '',
      'nas_name': pageFields['nas_name'] ?? '',
      'last_url': pageFields['last_url'] ?? '',
      'request_ip': pageFields['request_ip'] ?? '',
      'device_mode': profile.deviceMode,
      'device_type': profile.deviceType,
      'device_os_type': profile.deviceOsType,
      'is_mobile': profile.isMobile,
      'iv': pageFields['iv'] ?? '',
      'login_type': pageFields['login_type'] ?? '',
      'account_type': pageFields['account_type'] ?? '',
      'user_account': username,
      'user_password': password,
    };
  }

  Future<_PortalResponse> _postLoginAction({
    required http.Client client,
    required Uri baseUri,
    required Uri loginUri,
    required String sessionId,
    required DeviceProfile profile,
    required String encryptedPayload,
    required String iv,
  }) async {
    final response = await client.post(
      baseUri.resolve('/gportal/Web/loginAction'),
      headers: _jsonHeaders(
        baseUri: baseUri,
        referer: loginUri,
        sessionId: sessionId,
        userAgent: profile.userAgent,
      ),
      body:
          'data=${Uri.encodeQueryComponent(encryptedPayload)}'
          '&iv=${Uri.encodeQueryComponent(iv)}',
    );

    _ensureOk(response, '发送登录请求');
    return _PortalResponse.fromJsonBody(response.body, baseUri);
  }

  Future<_PortalResponse> _postBindSta({
    required http.Client client,
    required Uri baseUri,
    required String bindPath,
    required Uri loginUri,
    required String sessionId,
    required DeviceProfile profile,
  }) async {
    final response = await client.post(
      baseUri.resolve(bindPath),
      headers: _jsonHeaders(
        baseUri: baseUri,
        referer: loginUri,
        sessionId: sessionId,
        userAgent: profile.userAgent,
      ),
    );

    _ensureOk(response, '发送 bindSta');
    return _PortalResponse.fromJsonBody(response.body, baseUri);
  }

  void _ensureOk(http.Response response, String action) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('$action失败，HTTP ${response.statusCode}');
    }
  }

  Map<String, String> _jsonHeaders({
    required Uri baseUri,
    required Uri referer,
    required String sessionId,
    required String userAgent,
  }) {
    return <String, String>{
      'Accept': 'application/json, text/javascript, */*; q=0.01',
      'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      'Cookie': 'PHPSESSID=$sessionId',
      'Origin': baseUri.origin,
      'Referer': referer.toString(),
      'User-Agent': userAgent,
      'X-Requested-With': 'XMLHttpRequest',
    };
  }

  String _extractPhpSessionId(Map<String, String> headers) {
    final cookieHeader = headers['set-cookie'];
    final match = RegExp(
      r'PHPSESSID=([^;,\s]+)',
    ).firstMatch(cookieHeader ?? '');
    if (match == null) {
      throw const FormatException('未能从登录页响应中提取 PHPSESSID');
    }
    return match.group(1)!;
  }

  Map<String, String> _parseHiddenFields(String html) {
    final document = html_parser.parse(html);
    final fields = <String, String>{};

    for (final input in document.querySelectorAll('input[name]')) {
      final name = input.attributes['name'];
      if (name == null || name.isEmpty || fields.containsKey(name)) {
        continue;
      }
      fields[name] = input.attributes['value'] ?? '';
    }

    return fields;
  }

  void _validatePageFields(Map<String, String> fields) {
    final missingFields = <String>[];
    for (final field in kPortalFieldOrder) {
      if (field == 'user_account' || field == 'user_password') {
        continue;
      }
      if (!fields.containsKey(field)) {
        missingFields.add(field);
      }
    }

    if (missingFields.isNotEmpty) {
      throw FormatException('登录页缺少字段: ${missingFields.join(', ')}');
    }

    final iv = fields['iv'] ?? '';
    if (iv.length != 16) {
      throw FormatException('iv 长度异常: ${iv.length}');
    }

    if ((fields['sign'] ?? '').isEmpty) {
      throw const FormatException('sign 为空');
    }
  }
}

String serializePortalFields(Map<String, String> fields) {
  return kPortalFieldOrder
      .map((String name) {
        final value = fields[name] ?? '';
        return '$name=${Uri.encodeQueryComponent(value)}';
      })
      .join('&');
}

String encryptPortalPayload({required String plaintext, required String iv}) {
  final ivBytes = Uint8List.fromList(utf8.encode(iv));
  final inputBytes = Uint8List.fromList(utf8.encode(plaintext));
  final paddedBytes = zeroPadToBlockSize(inputBytes);

  final cipher = CBCBlockCipher(AESEngine())
    ..init(
      true,
      ParametersWithIV<KeyParameter>(KeyParameter(_aesKeyBytes), ivBytes),
    );

  final output = Uint8List(paddedBytes.length);
  for (
    var offset = 0;
    offset < paddedBytes.length;
    offset += cipher.blockSize
  ) {
    cipher.processBlock(paddedBytes, offset, output, offset);
  }

  return base64Encode(output);
}

Uint8List zeroPadToBlockSize(Uint8List input, {int blockSize = 16}) {
  final remainder = input.length % blockSize;
  if (remainder == 0) {
    return Uint8List.fromList(input);
  }

  final paddedLength = input.length + (blockSize - remainder);
  final output = Uint8List(paddedLength)..setRange(0, input.length, input);
  return output;
}

String buildAppPortalSignedPayload(
  Map<String, String> fields, {
  String? passwordField,
}) {
  final rawForSign = serializeSortedAppPortalFields(fields);
  final signature = md5Hex('$rawForSign$_appPortalSignSecret');
  final encodedFields = Map<String, String>.from(fields);

  if (passwordField != null && encodedFields.containsKey(passwordField)) {
    encodedFields[passwordField] = javaFormUrlEncode(
      encodedFields[passwordField]!,
    );
  }

  return '${serializeSortedAppPortalFields(encodedFields)}&sign=$signature';
}

String serializeSortedAppPortalFields(Map<String, String> fields) {
  final sortedFields = SplayTreeMap<String, String>.from(fields);
  return sortedFields.entries
      .map((MapEntry<String, String> entry) => '${entry.key}=${entry.value}')
      .join('&');
}

String md5Hex(String value) {
  final digest = MD5Digest().process(Uint8List.fromList(utf8.encode(value)));
  return digest
      .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

String javaFormUrlEncode(String value) {
  final output = StringBuffer();
  for (final byte in utf8.encode(value)) {
    final isAlphaNumeric =
        (byte >= 0x30 && byte <= 0x39) ||
        (byte >= 0x41 && byte <= 0x5a) ||
        (byte >= 0x61 && byte <= 0x7a);
    final isJavaSafe =
        isAlphaNumeric ||
        byte == 0x2d ||
        byte == 0x5f ||
        byte == 0x2e ||
        byte == 0x2a;

    if (isJavaSafe) {
      output.writeCharCode(byte);
    } else if (byte == 0x20) {
      output.write('+');
    } else {
      output
        ..write('%')
        ..write(byte.toRadixString(16).padLeft(2, '0').toUpperCase());
    }
  }
  return output.toString();
}

String javaFormUrlDecode(String value) {
  return Uri.decodeComponent(value.replaceAll('+', ' '));
}

String encryptAppPortalPayload(String plaintext) {
  final input = Uint8List.fromList(utf8.encode(plaintext));
  final padded = pkcs7PadToBlockSize(input);
  final cipher = AESEngine()..init(true, KeyParameter(_appPortalAesKeyBytes));
  final output = Uint8List(padded.length);

  for (var offset = 0; offset < padded.length; offset += cipher.blockSize) {
    cipher.processBlock(padded, offset, output, offset);
  }

  return base64Encode(output);
}

String encodeAppPortalData(String plaintext) {
  return javaFormUrlEncode(encryptAppPortalPayload(plaintext));
}

String decryptAppPortalData(String encodedData) {
  var encryptedBase64 = javaFormUrlDecode(encodedData);
  if (encryptedBase64.contains('%')) {
    encryptedBase64 = javaFormUrlDecode(encryptedBase64);
  }

  final encrypted = base64Decode(encryptedBase64);
  if (encrypted.isEmpty || encrypted.length % 16 != 0) {
    throw const FormatException('App Portal AES 密文长度异常');
  }

  final cipher = AESEngine()..init(false, KeyParameter(_appPortalAesKeyBytes));
  final padded = Uint8List(encrypted.length);
  for (var offset = 0; offset < encrypted.length; offset += cipher.blockSize) {
    cipher.processBlock(encrypted, offset, padded, offset);
  }

  return utf8.decode(pkcs7Unpad(padded));
}

Uint8List pkcs7PadToBlockSize(Uint8List input, {int blockSize = 16}) {
  final paddingLength = blockSize - (input.length % blockSize);
  final output = Uint8List(input.length + paddingLength)
    ..setRange(0, input.length, input)
    ..fillRange(input.length, input.length + paddingLength, paddingLength);
  return output;
}

Uint8List pkcs7Unpad(Uint8List input, {int blockSize = 16}) {
  if (input.isEmpty || input.length % blockSize != 0) {
    throw const FormatException('PKCS7 数据长度异常');
  }

  final paddingLength = input.last;
  if (paddingLength < 1 || paddingLength > blockSize) {
    throw const FormatException('PKCS7 padding 异常');
  }

  final payloadLength = input.length - paddingLength;
  for (var index = payloadLength; index < input.length; index++) {
    if (input[index] != paddingLength) {
      throw const FormatException('PKCS7 padding 异常');
    }
  }

  return Uint8List.fromList(input.sublist(0, payloadLength));
}

String _firstNonEmpty(Iterable<String?> values) {
  for (final value in values) {
    if (value != null && value.trim().isNotEmpty) {
      return value.trim();
    }
  }
  return '';
}

String _firstUsableMac(Iterable<String?> values) {
  for (final value in values) {
    if (value == null) {
      continue;
    }
    final normalized = normalizeMacAddress(value);
    if (isUsableMacAddress(normalized)) {
      return normalized;
    }
  }
  return '';
}

bool _isAppPortalLoginUri(Uri uri) {
  return uri.path.toLowerCase().contains('/gportal/web/login');
}

Uri _appPortalTransportUri(Uri uri) {
  // Preserve an omitted port so `Uri.origin` remains the canonical origin
  // returned by the captive redirect (rather than materialising `:80`).
  return uri.replace(scheme: 'http', port: uri.hasPort ? uri.port : null);
}

String _firstAppDataValue(_AppPortalResponse response, Iterable<String> keys) {
  return _firstNonEmpty(keys.map(response.dataString));
}

String _firstMapValue(Map<String, String> values, Iterable<String> keys) {
  return _firstNonEmpty(keys.map((String key) => values[key]));
}

String _appPortalNasNameForWire(String value) {
  final normalized = value.trim();
  // The successful APK request uses this lower-case cache value even though
  // the captive-portal redirect and queryAuthState response return upper case.
  return normalized.toUpperCase() == 'GIWIFI-BAS' ? 'giwifi-bas' : normalized;
}

String _resolveIp(Map<String, String> pageFields) {
  final staIp = pageFields['sta_ip'];
  if (staIp != null && staIp.isNotEmpty) {
    return staIp;
  }

  final requestIp = pageFields['request_ip'];
  if (requestIp != null && requestIp.isNotEmpty) {
    return requestIp;
  }

  return '未知';
}

class _LoginPageContext {
  const _LoginPageContext({
    required this.loginUri,
    required this.sessionId,
    required this.pageFields,
  });

  final Uri loginUri;
  final String sessionId;
  final Map<String, String> pageFields;

  String get iv => pageFields['iv']!;
}

class _AppPortalContext {
  const _AppPortalContext({
    required this.portalUri,
    required this.userIp,
    required this.nasName,
    required this.userMac,
    this.interfaceName = '',
    this.staModel = '',
    this.gatewayIp = '',
  });

  final Uri portalUri;
  final String userIp;
  final String nasName;
  final String userMac;
  final String interfaceName;
  final String staModel;
  final String gatewayIp;

  _AppPortalContext copyWith({
    Uri? portalUri,
    String? userIp,
    String? nasName,
    String? userMac,
    String? interfaceName,
    String? staModel,
    String? gatewayIp,
  }) {
    return _AppPortalContext(
      portalUri: portalUri ?? this.portalUri,
      userIp: userIp ?? this.userIp,
      nasName: nasName ?? this.nasName,
      userMac: userMac ?? this.userMac,
      interfaceName: interfaceName ?? this.interfaceName,
      staModel: staModel ?? this.staModel,
      gatewayIp: gatewayIp ?? this.gatewayIp,
    );
  }
}

bool _isAuthenticatedAppState(int? authState) {
  return authState == 2 || authState == 200;
}

class _AppAccountLoginResponse {
  const _AppAccountLoginResponse({
    required this.resultCode,
    required this.resultMsg,
    required this.info,
  });

  final int? resultCode;
  final String resultMsg;
  final String info;

  bool get isSuccess => resultCode == 0;

  String get displayInfo {
    if (resultMsg.trim().isNotEmpty) {
      return resultMsg.trim();
    }
    if (info.trim().isNotEmpty) {
      return info.trim();
    }
    return resultCode == null
        ? 'App 账号认证失败'
        : 'App 账号认证失败（resultCode=$resultCode）';
  }

  factory _AppAccountLoginResponse.fromJsonBody(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('App 账号认证返回格式异常');
    }

    final outer = Map<String, dynamic>.from(decoded);
    var payload = outer;
    final rawData = outer['data'];
    if (!_hasErrorCode(payload) && rawData is Map) {
      payload = <String, dynamic>{
        ...outer,
        ...Map<String, dynamic>.from(rawData),
      };
    } else if (!_hasErrorCode(payload) && rawData is String) {
      final trimmed = rawData.trim();
      if (trimmed.startsWith('{')) {
        try {
          final nested = jsonDecode(trimmed);
          if (nested is Map) {
            payload = <String, dynamic>{
              ...outer,
              ...Map<String, dynamic>.from(nested),
            };
          }
        } on FormatException {
          // Keep the outer response; the result code is normally top-level.
        }
      }
    }

    return _AppAccountLoginResponse(
      resultCode: _parseInt(
        payload['resultCode'] ?? payload['errorCode'] ?? payload['errcode'],
      ),
      resultMsg:
          payload['resultMsg']?.toString() ??
          payload['errmsg']?.toString() ??
          payload['message']?.toString() ??
          '',
      info: outer['info']?.toString() ?? '',
    );
  }
}

class _AppPortalResponse {
  const _AppPortalResponse({
    required this.errorCode,
    required this.info,
    required this.data,
  });

  final int? errorCode;
  final String info;
  final Map<String, dynamic>? data;

  bool get isSuccess => errorCode == 0;

  bool get requiresBind {
    return errorCode == 43 ||
        ((errorCode == 1 || errorCode == 203) && info.contains('绑定'));
  }

  String get displayInfo {
    final tips = dataString('tips');
    if (tips != null && tips.trim().isNotEmpty) {
      return tips.trim();
    }
    if (info.isNotEmpty) {
      return info;
    }
    if (isSuccess) {
      return '认证成功';
    }
    return errorCode == null ? '认证失败' : '认证失败（resultCode=$errorCode）';
  }

  String? dataString(String key) {
    final value = data?[key];
    if (value == null) {
      return null;
    }
    return value.toString();
  }

  int? dataInt(String key) => _parseInt(data?[key]);

  factory _AppPortalResponse.fromJsonBody(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('App Portal 返回格式异常');
    }

    final outer = Map<String, dynamic>.from(decoded);
    final outerData = outer['data'];
    Map<String, dynamic> inner;

    if (_hasErrorCode(outer)) {
      inner = outer;
    } else if (outerData is String && outerData.isNotEmpty) {
      final decrypted = decryptAppPortalData(outerData);
      final decodedInner = jsonDecode(decrypted);
      if (decodedInner is! Map) {
        throw const FormatException('App Portal 解密数据格式异常');
      }
      inner = Map<String, dynamic>.from(decodedInner);
    } else if (outerData is Map) {
      final nested = Map<String, dynamic>.from(outerData);
      if (_hasErrorCode(nested)) {
        inner = nested;
      } else {
        return _AppPortalResponse(
          errorCode: null,
          info: outer['info']?.toString() ?? '',
          data: nested,
        );
      }
    } else {
      throw const FormatException('App Portal 响应缺少 data');
    }

    final responseData = inner['data'] ?? inner['resultData'];
    return _AppPortalResponse(
      errorCode: _parseInt(
        inner['resultCode'] ?? inner['errcode'] ?? inner['errorCode'],
      ),
      info:
          inner['resultMsg']?.toString() ??
          inner['errmsg']?.toString() ??
          outer['info']?.toString() ??
          '',
      data: _appResponseDataMap(responseData),
    );
  }
}

Map<String, dynamic>? _appResponseDataMap(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  if (value is String && value.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      return null;
    }
  }
  return null;
}

bool _hasErrorCode(Map<String, dynamic> value) {
  return value.containsKey('errcode') ||
      value.containsKey('errorCode') ||
      value.containsKey('resultCode');
}

int? _parseInt(Object? value) {
  if (value is int) {
    return value;
  }
  return value == null ? null : int.tryParse(value.toString());
}

class _PortalResponse {
  const _PortalResponse({
    required this.status,
    required this.info,
    required this.data,
    required this.baseUri,
    this.resultCode,
    this.bindPath,
  });

  final int status;
  final String info;
  final Object? data;
  final Uri baseUri;
  final int? resultCode;
  final String? bindPath;

  bool get isSuccess => status == 1;

  bool get requiresBind => status == 0 && resultCode == 124 && bindPath != null;

  Uri? get logoutUrl {
    if (data is! String || (data as String).isEmpty) {
      return null;
    }
    return baseUri.resolve('/gportal/web/${data as String}');
  }

  factory _PortalResponse.fromJsonBody(String body, Uri baseUri) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Portal 返回格式异常');
    }

    final data = decoded['data'];
    final resultCode = data is Map<String, dynamic>
        ? int.tryParse('${data['resultCode']}')
        : null;
    final bindPath = data is Map<String, dynamic>
        ? data['resultData']?.toString()
        : null;

    return _PortalResponse(
      status: int.tryParse('${decoded['status']}') ?? 0,
      info: decoded['info']?.toString() ?? '',
      data: data,
      baseUri: baseUri,
      resultCode: resultCode,
      bindPath: bindPath,
    );
  }
}
