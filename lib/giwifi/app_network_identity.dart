import 'dart:io';

import 'package:flutter/services.dart';

typedef AppNetworkIdentityResolver =
    Future<AppNetworkIdentity> Function(Uri portalUri);

class AppNetworkIdentity {
  const AppNetworkIdentity({
    required this.userIp,
    required this.userMac,
    this.interfaceName = '',
    this.staModel = '',
    this.gatewayIp = '',
  });

  final String userIp;
  final String userMac;
  final String interfaceName;
  final String staModel;

  /// IPv4 gateway selected for the same route as [userIp].  The APK sends
  /// this value as the encrypted inner `gwAddress` field in its account-layer
  /// request.  It is optional because a directly-connected route has no
  /// `via` gateway and some Android APIs omit it on older releases.
  final String gatewayIp;
}

class LinuxRouteIdentity {
  const LinuxRouteIdentity({
    required this.interfaceName,
    required this.sourceIp,
    this.gatewayIp = '',
  });

  final String interfaceName;
  final String sourceIp;
  final String gatewayIp;
}

const MethodChannel _androidNetworkIdentityChannel = MethodChannel(
  'xgiwifi/network_identity',
);

final RegExp _macAddressPattern = RegExp(
  r'^[0-9A-F]{2}(?::[0-9A-F]{2}){5}$',
  caseSensitive: false,
);

const Set<String> _invalidMacAddresses = <String>{
  '00:00:00:00:00:00',
  '02:00:00:00:00:00',
};

bool isUsableIpv4Address(String value) {
  final address = InternetAddress.tryParse(value.trim());
  return address != null &&
      address.type == InternetAddressType.IPv4 &&
      !address.isLoopback &&
      !address.isLinkLocal &&
      address.address != '0.0.0.0';
}

bool isUsableMacAddress(String value) {
  final normalized = value.trim().toUpperCase();
  return _macAddressPattern.hasMatch(normalized) &&
      !_invalidMacAddresses.contains(normalized);
}

String normalizeMacAddress(String value) {
  final trimmed = value.trim();
  final compact = trimmed.replaceAll(RegExp(r'[-:.\s]'), '');
  if (compact.length != 12 || !RegExp(r'^[0-9A-Fa-f]{12}$').hasMatch(compact)) {
    return trimmed.toUpperCase();
  }

  return List<String>.generate(
    6,
    (int index) => compact.substring(index * 2, index * 2 + 2),
  ).join(':').toUpperCase();
}

Future<AppNetworkIdentity> resolveAppNetworkIdentity(Uri portalUri) async {
  if (Platform.isAndroid) {
    final androidIdentity = await _resolveAndroidNetworkIdentity(portalUri);
    if (androidIdentity != null) {
      return androidIdentity;
    }
  }

  return _resolvePosixNetworkIdentity(portalUri);
}

Future<AppNetworkIdentity?> _resolveAndroidNetworkIdentity(
  Uri portalUri,
) async {
  try {
    final value = await _androidNetworkIdentityChannel
        .invokeMapMethod<String, dynamic>(
          'getNetworkIdentity',
          <String, Object>{'portalHost': portalUri.host},
        );
    if (value == null) {
      return null;
    }

    final userIp = value['userIp']?.toString().trim() ?? '';
    final userMac = normalizeMacAddress(value['userMac']?.toString() ?? '');
    final gatewayIp = value['gatewayIp']?.toString().trim() ?? '';
    if (!isUsableIpv4Address(userIp)) {
      return null;
    }

    return AppNetworkIdentity(
      userIp: userIp,
      userMac: isUsableMacAddress(userMac) ? userMac : '',
      interfaceName: value['interfaceName']?.toString().trim() ?? '',
      staModel: value['staModel']?.toString().trim() ?? '',
      gatewayIp: isUsableIpv4Address(gatewayIp) ? gatewayIp : '',
    );
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

Future<AppNetworkIdentity> _resolvePosixNetworkIdentity(Uri portalUri) async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  final linuxRoute = await _resolveLinuxPortalRoute(portalUri);
  final routedIpv4 = linuxRoute?.sourceIp ?? '';

  NetworkInterface? routedInterface;
  if (linuxRoute != null) {
    if (_looksLikeVirtualInterface(linuxRoute.interfaceName)) {
      throw FormatException(
        'Portal 路由指向虚拟接口 ${linuxRoute.interfaceName}，'
        '未使用其他网卡身份替代',
      );
    }
    for (final interface in interfaces) {
      if (interface.name == linuxRoute.interfaceName &&
          !_looksLikeVirtualInterface(interface.name)) {
        routedInterface = interface;
        break;
      }
    }
    if (routedInterface == null) {
      throw FormatException(
        'Portal 路由接口 ${linuxRoute.interfaceName} 不在当前 IPv4 网卡列表中',
      );
    }
    final sourceBelongsToInterface = routedInterface.addresses.any(
      (InternetAddress address) => address.address == linuxRoute.sourceIp,
    );
    if (!sourceBelongsToInterface) {
      throw FormatException(
        'Portal 路由源地址 ${linuxRoute.sourceIp} '
        '不属于接口 ${linuxRoute.interfaceName}',
      );
    }
  }
  if (routedInterface == null && routedIpv4.isNotEmpty) {
    for (final interface in interfaces) {
      if (!_looksLikeVirtualInterface(interface.name) &&
          interface.addresses.any(
            (InternetAddress address) => address.address == routedIpv4,
          )) {
        routedInterface = interface;
        break;
      }
    }
  }

  final preferredInterface = await _readDefaultRouteInterface();
  final ordered = <NetworkInterface>[
    ?routedInterface,
    ...interfaces.where(
      (NetworkInterface interface) =>
          interface.name != routedInterface?.name &&
          interface.name == preferredInterface &&
          !_looksLikeVirtualInterface(interface.name),
    ),
    ...interfaces.where(
      (NetworkInterface interface) =>
          interface.name != routedInterface?.name &&
          interface.name != preferredInterface &&
          !_looksLikeVirtualInterface(interface.name),
    ),
  ];

  for (final interface in ordered) {
    final interfaceAddresses = interface.addresses
        .map((InternetAddress address) => address.address)
        .where(isUsableIpv4Address)
        .toList(growable: false);
    final userIp =
        interface.name == routedInterface?.name &&
            interfaceAddresses.contains(routedIpv4)
        ? routedIpv4
        : interfaceAddresses.firstOrNull ?? '';
    if (userIp.isEmpty) {
      continue;
    }

    final userMac = await _readInterfaceMac(interface.name);

    return AppNetworkIdentity(
      userIp: userIp,
      userMac: isUsableMacAddress(userMac) ? userMac : '',
      interfaceName: interface.name,
      gatewayIp: linuxRoute?.gatewayIp ?? '',
    );
  }

  throw const FormatException('未获取到当前网络接口的有效 IPv4 地址');
}

Future<LinuxRouteIdentity?> _resolveLinuxPortalRoute(Uri portalUri) async {
  if (!Platform.isLinux || portalUri.host.isEmpty) {
    return null;
  }

  final destinationIpv4 = await _resolveDestinationIpv4(portalUri.host);
  if (destinationIpv4.isEmpty) {
    return null;
  }

  const executables = <String>[
    '/usr/sbin/ip',
    '/sbin/ip',
    '/usr/bin/ip',
    '/bin/ip',
    'ip',
  ];
  for (final executable in executables) {
    if (executable.startsWith('/') && !await File(executable).exists()) {
      continue;
    }
    try {
      final result = await Process.run(executable, <String>[
        '-4',
        '-o',
        'route',
        'get',
        destinationIpv4,
      ]);
      if (result.exitCode != 0) {
        continue;
      }
      final route = parseLinuxRouteGetOutput(result.stdout.toString());
      if (route != null) {
        return route;
      }
    } on ProcessException {
      continue;
    }
  }

  return null;
}

Future<String> _resolveDestinationIpv4(String host) async {
  final parsed = InternetAddress.tryParse(host);
  if (parsed?.type == InternetAddressType.IPv4) {
    return parsed!.address;
  }

  try {
    final addresses = await InternetAddress.lookup(
      host,
      type: InternetAddressType.IPv4,
    );
    return addresses
        .map((InternetAddress address) => address.address)
        .firstWhere(isUsableIpv4Address, orElse: () => '');
  } on SocketException {
    return '';
  }
}

LinuxRouteIdentity? parseLinuxRouteGetOutput(String output) {
  for (final line in output.split('\n')) {
    final tokens = line.trim().split(RegExp(r'\s+'));
    final devIndex = tokens.indexOf('dev');
    final srcIndex = tokens.indexOf('src');
    final viaIndex = tokens.indexOf('via');
    if (devIndex < 0 ||
        devIndex + 1 >= tokens.length ||
        srcIndex < 0 ||
        srcIndex + 1 >= tokens.length) {
      continue;
    }

    final interfaceName = tokens[devIndex + 1].trim();
    final sourceIp = tokens[srcIndex + 1].trim();
    if (interfaceName.isEmpty || !isUsableIpv4Address(sourceIp)) {
      continue;
    }

    final gatewayIp = viaIndex >= 0 && viaIndex + 1 < tokens.length
        ? tokens[viaIndex + 1].trim()
        : '';
    return LinuxRouteIdentity(
      interfaceName: interfaceName,
      sourceIp: sourceIp,
      gatewayIp: isUsableIpv4Address(gatewayIp) ? gatewayIp : '',
    );
  }

  return null;
}

Future<String> _readDefaultRouteInterface() async {
  if (!Platform.isLinux && !Platform.isAndroid) {
    return '';
  }

  try {
    final lines = await File('/proc/net/route').readAsLines();
    String selected = '';
    var selectedMetric = 1 << 30;
    for (final line in lines.skip(1)) {
      final columns = line.trim().split(RegExp(r'\s+'));
      if (columns.length < 8 || columns[1] != '00000000') {
        continue;
      }

      final flags = int.tryParse(columns[3], radix: 16) ?? 0;
      final metric = int.tryParse(columns[6]) ?? selectedMetric;
      if ((flags & 0x1) == 0 || metric >= selectedMetric) {
        continue;
      }

      final name = columns[0];
      if (_looksLikeVirtualInterface(name)) {
        continue;
      }
      selected = name;
      selectedMetric = metric;
    }
    return selected;
  } on FileSystemException {
    return '';
  }
}

Future<String> _readInterfaceMac(String interfaceName) async {
  if (!Platform.isLinux && !Platform.isAndroid) {
    return '';
  }

  try {
    final value = await File(
      '/sys/class/net/$interfaceName/address',
    ).readAsString();
    return normalizeMacAddress(value);
  } on FileSystemException {
    return '';
  }
}

bool _looksLikeVirtualInterface(String name) {
  final normalized = name.toLowerCase();
  return normalized == 'lo' ||
      normalized.startsWith('tun') ||
      normalized.startsWith('tap') ||
      normalized.startsWith('ppp') ||
      normalized.startsWith('wg') ||
      normalized.startsWith('vpn') ||
      normalized.startsWith('rmnet') ||
      normalized.startsWith('ccmni') ||
      normalized.startsWith('pdp') ||
      normalized.startsWith('wwan') ||
      normalized.startsWith('docker') ||
      normalized.startsWith('veth') ||
      normalized.startsWith('virbr') ||
      normalized.startsWith('br-') ||
      normalized == 'meta';
}
