import 'dart:convert';
import 'dart:typed_data';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';

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

class GiWifiClient {
  GiWifiClient({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() _clientFactory;

  Future<LoginResult> login({
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
            await Future<void>.delayed(const Duration(seconds: 2));
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
