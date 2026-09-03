import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_network_identity.dart';

enum WindowsNetworkAdapterKind { wifi, ethernet, other }

class WindowsNetworkAdapter {
  const WindowsNetworkAdapter({
    required this.id,
    required this.name,
    required this.systemName,
    required this.ipv4,
    required this.macAddress,
    required this.gatewayIp,
    required this.kind,
    required this.isVirtual,
  });

  factory WindowsNetworkAdapter.fromMap(Map<Object?, Object?> map) {
    String value(String key) => map[key]?.toString().trim() ?? '';
    final id = value('id');
    final ipv4 = value('ipv4');
    if (id.isEmpty || !isUsableIpv4Address(ipv4)) {
      throw const FormatException('Windows 网卡数据缺少有效 ID 或 IPv4');
    }

    final kind = switch (value('kind')) {
      'wifi' => WindowsNetworkAdapterKind.wifi,
      'ethernet' => WindowsNetworkAdapterKind.ethernet,
      _ => WindowsNetworkAdapterKind.other,
    };
    final systemName = value('systemName');
    final name = value('name');

    return WindowsNetworkAdapter(
      id: id,
      name: name.isEmpty ? systemName : name,
      systemName: systemName,
      ipv4: ipv4,
      macAddress: normalizeMacAddress(value('macAddress')),
      gatewayIp: value('gatewayIp'),
      kind: kind,
      isVirtual: map['isVirtual'] == true,
    );
  }

  final String id;
  final String name;
  final String systemName;
  final String ipv4;
  final String macAddress;
  final String gatewayIp;
  final WindowsNetworkAdapterKind kind;
  final bool isVirtual;

  AppNetworkIdentity get identity => AppNetworkIdentity(
    userIp: ipv4,
    userMac: isUsableMacAddress(macAddress) ? macAddress : '',
    interfaceName: systemName,
    gatewayIp: isUsableIpv4Address(gatewayIp) ? gatewayIp : '',
  );

  String get typeLabel => switch (kind) {
    WindowsNetworkAdapterKind.wifi => 'Wi-Fi',
    WindowsNetworkAdapterKind.ethernet => '有线',
    WindowsNetworkAdapterKind.other => '其他',
  };

  @override
  bool operator ==(Object other) =>
      other is WindowsNetworkAdapter &&
      id == other.id &&
      name == other.name &&
      systemName == other.systemName &&
      ipv4 == other.ipv4 &&
      macAddress == other.macAddress &&
      gatewayIp == other.gatewayIp &&
      kind == other.kind &&
      isVirtual == other.isVirtual;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    systemName,
    ipv4,
    macAddress,
    gatewayIp,
    kind,
    isVirtual,
  );
}

List<WindowsNetworkAdapter> sortWindowsNetworkAdapters(
  Iterable<WindowsNetworkAdapter> adapters,
) {
  final result = adapters.toList();
  result.sort((WindowsNetworkAdapter left, WindowsNetworkAdapter right) {
    final virtualOrder = (left.isVirtual ? 1 : 0).compareTo(
      right.isVirtual ? 1 : 0,
    );
    if (virtualOrder != 0) {
      return virtualOrder;
    }
    return left.name.toLowerCase().compareTo(right.name.toLowerCase());
  });
  return List<WindowsNetworkAdapter>.unmodifiable(result);
}

WindowsNetworkAdapter? findWindowsNetworkAdapter(
  Iterable<WindowsNetworkAdapter> adapters,
  String id,
) {
  if (id.isEmpty) {
    return null;
  }
  for (final adapter in adapters) {
    if (adapter.id == id) {
      return adapter;
    }
  }
  return null;
}

typedef WindowsNetworkAdapterLoader =
    Future<List<WindowsNetworkAdapter>> Function();

class WindowsNetworkAdapterService {
  const WindowsNetworkAdapterService({
    MethodChannel channel = const MethodChannel(
      'xgiwifi/windows_network_adapters',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<List<WindowsNetworkAdapter>> listAdapters() async {
    if (defaultTargetPlatform != TargetPlatform.windows) {
      return const <WindowsNetworkAdapter>[];
    }

    final values =
        await _channel.invokeListMethod<Object?>('listAdapters') ??
        const <Object?>[];
    final adapters = values
        .whereType<Map<Object?, Object?>>()
        .map(WindowsNetworkAdapter.fromMap)
        .toList(growable: false);
    return sortWindowsNetworkAdapters(adapters);
  }
}
