import 'package:flutter_test/flutter_test.dart';
import 'package:xgiwifi/giwifi/windows_network_adapter.dart';

void main() {
  const wifi = WindowsNetworkAdapter(
    id: '{WIFI}',
    name: 'Intel Wi-Fi',
    systemName: 'Wi-Fi',
    ipv4: '10.20.30.40',
    macAddress: 'AA:BB:CC:DD:EE:01',
    gatewayIp: '10.20.30.1',
    kind: WindowsNetworkAdapterKind.wifi,
    isVirtual: false,
  );
  const ethernet = WindowsNetworkAdapter(
    id: '{ETHERNET}',
    name: 'Realtek Ethernet',
    systemName: 'Ethernet',
    ipv4: '10.10.0.8',
    macAddress: 'AA:BB:CC:DD:EE:02',
    gatewayIp: '10.10.0.1',
    kind: WindowsNetworkAdapterKind.ethernet,
    isVirtual: false,
  );
  const virtualAdapter = WindowsNetworkAdapter(
    id: '{VIRTUAL}',
    name: 'Hyper-V Virtual Ethernet Adapter',
    systemName: 'vEthernet',
    ipv4: '172.20.0.1',
    macAddress: 'AA:BB:CC:DD:EE:03',
    gatewayIp: '',
    kind: WindowsNetworkAdapterKind.other,
    isVirtual: true,
  );

  test('parses the native channel payload', () {
    final adapter = WindowsNetworkAdapter.fromMap(<Object?, Object?>{
      'id': wifi.id,
      'name': wifi.name,
      'systemName': wifi.systemName,
      'ipv4': wifi.ipv4,
      'macAddress': wifi.macAddress,
      'gatewayIp': wifi.gatewayIp,
      'kind': 'wifi',
      'isVirtual': false,
    });

    expect(adapter, wifi);
    expect(adapter.identity.userIp, wifi.ipv4);
    expect(adapter.identity.interfaceName, wifi.systemName);
  });

  test('orders physical adapters before virtual adapters', () {
    expect(
      sortWindowsNetworkAdapters(<WindowsNetworkAdapter>[
        virtualAdapter,
        wifi,
        ethernet,
      ]),
      <WindowsNetworkAdapter>[wifi, ethernet, virtualAdapter],
    );
  });

  test(
    'matches a persisted ID exactly and never substitutes another adapter',
    () {
      final adapters = <WindowsNetworkAdapter>[wifi, ethernet];

      expect(findWindowsNetworkAdapter(adapters, '{WIFI}'), wifi);
      expect(findWindowsNetworkAdapter(adapters, '{MISSING}'), isNull);
      expect(findWindowsNetworkAdapter(adapters, ''), isNull);
    },
  );
}
