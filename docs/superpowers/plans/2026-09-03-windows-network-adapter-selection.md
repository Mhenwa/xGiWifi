# Windows Network Adapter Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent Windows-only adapter selector that binds authentication traffic and App Portal identity fields to the chosen physical or virtual adapter, plus a clear wired/Wi-Fi usage notice.

**Architecture:** A focused Dart adapter model/service consumes a Windows method channel backed by `GetAdaptersAddresses`. `HomePage` refreshes and persists the selection, validates Ethernet/profile combinations, and passes an `AppNetworkIdentity` override into `GiWifiClient`; the client creates an `IOClient` whose sockets bind to that identity's IPv4 address. Android receives no new UI or platform-channel behavior.

**Tech Stack:** Flutter/Dart, `package:http`, `dart:io` `HttpClient.connectionFactory`, Flutter Windows C++ runner, Windows IP Helper API, Flutter widget/unit tests.

---

## File map

- Create `lib/giwifi/windows_network_adapter.dart`: immutable adapter model, map parsing, ordering, stable-ID lookup, and Windows method-channel loader.
- Create `lib/giwifi/source_bound_http_client.dart`: construct an `IOClient` whose sockets bind to one validated IPv4 source address.
- Create `windows/runner/network_adapter_channel.h` and `windows/runner/network_adapter_channel.cpp`: enumerate active adapters through `GetAdaptersAddresses` and expose them to Dart.
- Modify `windows/runner/flutter_window.h`, `windows/runner/flutter_window.cpp`, and `windows/runner/CMakeLists.txt`: own/register the channel and link Windows networking libraries.
- Modify `lib/app/app_settings.dart`: persist the stable selected-adapter ID; empty string means automatic.
- Modify `lib/giwifi/giwifi_client.dart`: accept a per-login network identity override and use the source-bound client factory.
- Modify `lib/app/home_page.dart`: Windows-only selector, refresh/fallback behavior, wired/Wi-Fi notice, validation, logs, and login handoff.
- Modify `test/app_settings_test.dart`, `test/giwifi_client_protocol_test.dart`, and `test/widget_test.dart`; create `test/windows_network_adapter_test.dart` and `test/source_bound_http_client_test.dart`.

### Task 1: Persist the selected Windows adapter ID

**Files:**
- Modify: `lib/app/app_settings.dart`
- Test: `test/app_settings_test.dart`

- [ ] **Step 1: Write failing settings tests**

Append a `Windows adapter selection` group:

```dart
group('Windows adapter selection', () {
  test('defaults to automatic selection', () {
    expect(const AppSettings().windowsAdapterId, isEmpty);
  });

  test('loads and saves the stable adapter ID', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'windows_adapter_id': '{ADAPTER-GUID}',
    });
    final store = AppSettingsStore();

    final loaded = await store.load();
    expect(loaded.windowsAdapterId, '{ADAPTER-GUID}');

    await store.save(loaded.copyWith(windowsAdapterId: ''));
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('windows_adapter_id'), isEmpty);
  });
});
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `flutter test test/app_settings_test.dart`

Expected: compilation fails because `windowsAdapterId` does not exist.

- [ ] **Step 3: Add the setting and storage key**

Update `AppSettings` and `AppSettingsStore`:

```dart
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.baseUrl = kDefaultBaseUrl,
    this.savedAccount = '',
    this.savedPassword = '',
    this.savedProfile = DeviceProfile.windows,
    this.appUuid = '',
    this.windowsAdapterId = '',
  });

  final String windowsAdapterId;

  AppSettings copyWith({
    ThemeMode? themeMode,
    String? baseUrl,
    String? savedAccount,
    String? savedPassword,
    DeviceProfile? savedProfile,
    String? appUuid,
    String? windowsAdapterId,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      baseUrl: baseUrl ?? this.baseUrl,
      savedAccount: savedAccount ?? this.savedAccount,
      savedPassword: savedPassword ?? this.savedPassword,
      savedProfile: savedProfile ?? this.savedProfile,
      appUuid: appUuid ?? this.appUuid,
      windowsAdapterId: windowsAdapterId ?? this.windowsAdapterId,
    );
  }
}
```

Add `_windowsAdapterIdKey = 'windows_adapter_id'`, read it with `.trim()` in `load`, pass it into `AppSettings`, and save it with `setString` in `save`.

- [ ] **Step 4: Run settings tests and verify GREEN**

Run: `flutter test test/app_settings_test.dart`

Expected: all settings tests pass.

- [ ] **Step 5: Commit**

```powershell
git add lib/app/app_settings.dart test/app_settings_test.dart
git commit -m "feat: persist Windows adapter selection"
```

### Task 2: Add the Dart adapter contract and selection rules

**Files:**
- Create: `lib/giwifi/windows_network_adapter.dart`
- Create: `test/windows_network_adapter_test.dart`

- [ ] **Step 1: Write failing model and ordering tests**

Create `test/windows_network_adapter_test.dart`:

```dart
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

  test('matches a persisted ID exactly and never substitutes another adapter', () {
    final adapters = <WindowsNetworkAdapter>[wifi, ethernet];
    expect(findWindowsNetworkAdapter(adapters, '{WIFI}'), wifi);
    expect(findWindowsNetworkAdapter(adapters, '{MISSING}'), isNull);
    expect(findWindowsNetworkAdapter(adapters, ''), isNull);
  });
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `flutter test test/windows_network_adapter_test.dart`

Expected: compilation fails because the adapter module is absent.

- [ ] **Step 3: Implement the immutable model and helpers**

Create `lib/giwifi/windows_network_adapter.dart` with:

```dart
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
    return WindowsNetworkAdapter(
      id: id,
      name: value('name').isEmpty ? value('systemName') : value('name'),
      systemName: value('systemName'),
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
  result.sort((left, right) {
    final virtualOrder = (left.isVirtual ? 1 : 0).compareTo(
      right.isVirtual ? 1 : 0,
    );
    if (virtualOrder != 0) return virtualOrder;
    return left.name.toLowerCase().compareTo(right.name.toLowerCase());
  });
  return List<WindowsNetworkAdapter>.unmodifiable(result);
}

WindowsNetworkAdapter? findWindowsNetworkAdapter(
  Iterable<WindowsNetworkAdapter> adapters,
  String id,
) {
  if (id.isEmpty) return null;
  for (final adapter in adapters) {
    if (adapter.id == id) return adapter;
  }
  return null;
}

```

- [ ] **Step 4: Run model tests and verify GREEN**

Run: `flutter test test/windows_network_adapter_test.dart`

Expected: all adapter model tests pass.

- [ ] **Step 5: Commit**

```powershell
git add lib/giwifi/windows_network_adapter.dart test/windows_network_adapter_test.dart
git commit -m "feat: model Windows network adapters"
```

### Task 3: Implement the Windows adapter method channel

**Files:**
- Create: `windows/runner/network_adapter_channel.h`
- Create: `windows/runner/network_adapter_channel.cpp`
- Modify: `windows/runner/flutter_window.h`
- Modify: `windows/runner/flutter_window.cpp`
- Modify: `windows/runner/CMakeLists.txt`
- Test: `test/windows_network_adapter_test.dart`

- [ ] **Step 1: Add a failing method-channel contract test**

Add imports for `flutter/material.dart` and `flutter/services.dart`, then add:

```dart
test('loads and sorts maps returned by the Windows channel', () async {
  TestWidgetsFlutterBinding.ensureInitialized();
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  const channel = MethodChannel('test/windows_network_adapters');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (MethodCall call) async {
        expect(call.method, 'listAdapters');
        return <Map<String, Object?>>[
          <String, Object?>{
            'id': '{VIRTUAL}',
            'name': 'Hyper-V',
            'systemName': 'vEthernet',
            'ipv4': '172.20.0.1',
            'macAddress': 'AA-BB-CC-DD-EE-03',
            'gatewayIp': '',
            'kind': 'other',
            'isVirtual': true,
          },
          <String, Object?>{
            'id': '{WIFI}',
            'name': 'Intel Wi-Fi',
            'systemName': 'Wi-Fi',
            'ipv4': '10.20.30.40',
            'macAddress': 'AA-BB-CC-DD-EE-01',
            'gatewayIp': '10.20.30.1',
            'kind': 'wifi',
            'isVirtual': false,
          },
        ];
      });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  final adapters = await const WindowsNetworkAdapterService(
    channel: channel,
  ).listAdapters();

  expect(adapters.map((adapter) => adapter.id), <String>['{WIFI}', '{VIRTUAL}']);
  expect(adapters.first.macAddress, 'AA:BB:CC:DD:EE:01');
});
```

- [ ] **Step 2: Run the contract test and verify RED**

Run: `flutter test test/windows_network_adapter_test.dart`

Expected: compilation fails because `WindowsNetworkAdapterService` has not been implemented.

- [ ] **Step 3: Implement the Dart channel service and verify GREEN**

Add these imports and declarations to `lib/giwifi/windows_network_adapter.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
    final values = await _channel.invokeListMethod<Object?>('listAdapters') ??
        const <Object?>[];
    final adapters = values
        .whereType<Map<Object?, Object?>>()
        .map(WindowsNetworkAdapter.fromMap)
        .toList(growable: false);
    return sortWindowsNetworkAdapters(adapters);
  }
}
```

Run: `flutter test test/windows_network_adapter_test.dart`

Expected: all Dart adapter tests pass.

- [ ] **Step 4: Add the native channel header**

Create `windows/runner/network_adapter_channel.h`:

```cpp
#ifndef RUNNER_NETWORK_ADAPTER_CHANNEL_H_
#define RUNNER_NETWORK_ADAPTER_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateNetworkAdapterChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_NETWORK_ADAPTER_CHANNEL_H_
```

- [ ] **Step 5: Implement native enumeration**

Create `windows/runner/network_adapter_channel.cpp`. Implement these exact responsibilities:

```cpp
#include "network_adapter_channel.h"

#include <iphlpapi.h>
#include <ws2tcpip.h>

#include <algorithm>
#include <cctype>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include <flutter/standard_method_codec.h>

#include "utils.h"

namespace {
constexpr char kChannelName[] = "xgiwifi/windows_network_adapters";

std::string Ipv4FromSockaddr(const SOCKADDR* address) {
  if (address == nullptr || address->sa_family != AF_INET) return "";
  const auto* ipv4 = reinterpret_cast<const SOCKADDR_IN*>(address);
  const auto raw = ntohl(ipv4->sin_addr.S_un.S_addr);
  if (raw == 0 || (raw >> 24) == 127 || (raw >> 16) == 0xA9FE) return "";
  char buffer[INET_ADDRSTRLEN] = {};
  return InetNtopA(AF_INET, const_cast<IN_ADDR*>(&ipv4->sin_addr), buffer,
                   INET_ADDRSTRLEN) == nullptr
             ? ""
             : buffer;
}

std::string FormatMac(const IP_ADAPTER_ADDRESSES* adapter) {
  if (adapter->PhysicalAddressLength != 6) return "";
  std::ostringstream value;
  value << std::uppercase << std::hex << std::setfill('0');
  for (ULONG index = 0; index < adapter->PhysicalAddressLength; ++index) {
    if (index != 0) value << ':';
    value << std::setw(2) << static_cast<int>(adapter->PhysicalAddress[index]);
  }
  return value.str();
}

std::string Lower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
  return value;
}

bool IsVirtual(const IP_ADAPTER_ADDRESSES* adapter, const std::string& label) {
  if (adapter->IfType == IF_TYPE_SOFTWARE_LOOPBACK ||
      adapter->IfType == IF_TYPE_TUNNEL) {
    return true;
  }
  const std::string adapter_name =
      adapter->AdapterName == nullptr ? "" : adapter->AdapterName;
  const auto text = Lower(label + " " + adapter_name);
  for (const auto* marker : {"virtual", "hyper-v", "vmware", "virtualbox",
                             "vethernet", "vpn", "tap", "tun", "wsl",
                             "docker", "loopback"}) {
    if (text.find(marker) != std::string::npos) return true;
  }
  return false;
}

std::string Kind(const IP_ADAPTER_ADDRESSES* adapter) {
  if (adapter->IfType == IF_TYPE_IEEE80211) return "wifi";
  if (adapter->IfType == IF_TYPE_ETHERNET_CSMACD) return "ethernet";
  return "other";
}

flutter::EncodableList ListAdapters() {
  ULONG size = 16 * 1024;
  std::vector<unsigned char> buffer(size);
  auto* addresses = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
  const ULONG flags = GAA_FLAG_INCLUDE_GATEWAYS | GAA_FLAG_SKIP_ANYCAST |
                      GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;
  ULONG status = GetAdaptersAddresses(AF_INET, flags, nullptr, addresses, &size);
  if (status == ERROR_BUFFER_OVERFLOW) {
    buffer.resize(size);
    addresses = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
    status = GetAdaptersAddresses(AF_INET, flags, nullptr, addresses, &size);
  }
  if (status == ERROR_NO_DATA) return {};
  if (status != NO_ERROR) {
    throw std::runtime_error("GetAdaptersAddresses failed: " +
                             std::to_string(status));
  }

  flutter::EncodableList result;
  for (auto* adapter = addresses; adapter != nullptr; adapter = adapter->Next) {
    if (adapter->OperStatus != IfOperStatusUp) continue;
    std::string ipv4;
    for (auto* address = adapter->FirstUnicastAddress; address != nullptr;
         address = address->Next) {
      ipv4 = Ipv4FromSockaddr(address->Address.lpSockaddr);
      if (!ipv4.empty()) break;
    }
    if (ipv4.empty()) continue;

    std::string gateway;
    for (auto* value = adapter->FirstGatewayAddress; value != nullptr;
         value = value->Next) {
      gateway = Ipv4FromSockaddr(value->Address.lpSockaddr);
      if (!gateway.empty()) break;
    }
    const auto name = Utf8FromUtf16(adapter->FriendlyName);
    const auto description = Utf8FromUtf16(adapter->Description);
    const auto label = name.empty() ? description : name;
    const std::string adapter_id =
        adapter->AdapterName == nullptr ? "" : adapter->AdapterName;
    result.emplace_back(flutter::EncodableMap{
        {flutter::EncodableValue("id"),
         flutter::EncodableValue(adapter_id)},
        {flutter::EncodableValue("name"), flutter::EncodableValue(label)},
        {flutter::EncodableValue("systemName"), flutter::EncodableValue(name)},
        {flutter::EncodableValue("ipv4"), flutter::EncodableValue(ipv4)},
        {flutter::EncodableValue("macAddress"),
         flutter::EncodableValue(FormatMac(adapter))},
        {flutter::EncodableValue("gatewayIp"), flutter::EncodableValue(gateway)},
        {flutter::EncodableValue("kind"), flutter::EncodableValue(Kind(adapter))},
        {flutter::EncodableValue("isVirtual"),
         flutter::EncodableValue(
             IsVirtual(adapter, label + " " + description))},
    });
  }
  return result;
}
}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateNetworkAdapterChannel(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() != "listAdapters") {
      result->NotImplemented();
      return;
    }
    try {
      result->Success(flutter::EncodableValue(ListAdapters()));
    } catch (const std::exception& error) {
      result->Error("ADAPTER_ENUMERATION_FAILED", error.what());
    }
  });
  return channel;
}
```

- [ ] **Step 6: Register and link the channel**

Add a channel member to `FlutterWindow`, initialize it after `RegisterPlugins`, reset it before the engine in `OnDestroy`, add `network_adapter_channel.cpp` to the executable, and link `iphlpapi.lib` plus `ws2_32.lib`:

In `flutter_window.h`, include the channel header and add this private member:

```cpp
#include "network_adapter_channel.h"

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
    network_adapter_channel_;
```

In `flutter_window.cpp`, create the channel after plugin registration:

```cpp
network_adapter_channel_ =
    CreateNetworkAdapterChannel(flutter_controller_->engine()->messenger());
```

Reset it before destroying the controller:

```cpp
if (flutter_controller_) {
  network_adapter_channel_.reset();
  flutter_controller_ = nullptr;
}
```

```cmake
"network_adapter_channel.cpp"
```

```cmake
target_link_libraries(${BINARY_NAME} PRIVATE "iphlpapi.lib" "ws2_32.lib")
```

- [ ] **Step 7: Verify the channel contract and Windows compilation**

Run:

```powershell
flutter test test/windows_network_adapter_test.dart
flutter build windows --debug
```

Expected: Dart contract tests pass and the Windows runner links without warnings promoted to errors.

- [ ] **Step 8: Commit**

```powershell
git add windows/runner lib/giwifi/windows_network_adapter.dart test/windows_network_adapter_test.dart
git commit -m "feat: enumerate Windows network adapters"
```

### Task 4: Bind HTTP traffic and App Portal identity to the selection

**Files:**
- Create: `lib/giwifi/source_bound_http_client.dart`
- Modify: `lib/giwifi/giwifi_client.dart`
- Create: `test/source_bound_http_client_test.dart`
- Modify: `test/giwifi_client_protocol_test.dart`

- [ ] **Step 1: Write a failing source-address validation test**

Create `test/source_bound_http_client_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:xgiwifi/giwifi/source_bound_http_client.dart';

void main() {
  test('rejects an unusable source IPv4 before creating a client', () {
    expect(
      () => createSourceBoundHttpClient('127.0.0.1'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => createSourceBoundHttpClient('not-an-ip'),
      throwsA(isA<FormatException>()),
    );
  });
}
```

- [ ] **Step 2: Write failing client-routing tests**

Import `windows_network_adapter.dart` and add this shared fixture:

```dart
const _selectedWindowsAdapter = WindowsNetworkAdapter(
  id: '{WIFI}',
  name: 'Intel Wi-Fi',
  systemName: 'Wi-Fi',
  ipv4: '10.20.30.40',
  macAddress: 'AA:BB:CC:DD:EE:01',
  gatewayIp: '10.20.30.1',
  kind: WindowsNetworkAdapterKind.wifi,
  isVirtual: false,
);
```

Add the Web Portal test inside its existing group:

```dart
test('Windows login uses the selected adapter source address', () async {
  String? boundSource;
  final client = MockClient((http.Request request) async {
    if (request.method == 'GET') {
      return http.Response(_windowsLoginHtml, 200);
    }
    return _jsonResponse(jsonEncode(<String, dynamic>{
      'status': 1,
      'info': '登录成功',
      'data': 'logout.html',
    }));
  });
  final giWifi = GiWifiClient(
    clientFactory: () => throw StateError('unbound client used'),
    networkBoundClientFactory: (String sourceIpv4) {
      boundSource = sourceIpv4;
      return client;
    },
  );

  final result = await giWifi.login(
    baseUrl: 'http://10.100.100.2',
    profile: DeviceProfile.windows,
    username: 'fixture-user',
    password: 'fixture-password',
    networkIdentity: _selectedWindowsAdapter.identity,
    onBindConflict: (_) async => false,
  );

  expect(result.outcome, LoginOutcome.success);
  expect(boundSource, '10.20.30.40');
});
```

Add the App Portal test inside its existing group:

```dart
test('App Portal uses selected adapter identity without auto resolution', () async {
  String? boundSource;
  var resolverCalled = false;
  final decodedRequests = <Map<String, String>>[];
  final client = MockClient((http.Request request) async {
    final fields = _decodeAppRequest(request);
    decodedRequests.add(fields);
    if (request.url.path == '/gportal/app/queryAuthState') {
      return _jsonResponse(_appResponse(<String, dynamic>{
        'resultCode': 0,
        'resultMsg': 'state ok',
        'data': <String, dynamic>{
          'authState': 1,
          'userMac': _selectedWindowsAdapter.macAddress,
          'nasName': 'NAS-FROM-STATE',
        },
      }));
    }
    expect(request.url.path, '/gportal/app/authLogin');
    return _jsonResponse(_appResponse(<String, dynamic>{
      'resultCode': 0,
      'resultMsg': '登录成功',
      'data': <String, dynamic>{'tips': '登录成功'},
    }));
  });
  final giWifi = GiWifiClient(
    clientFactory: () => throw StateError('unbound client used'),
    networkBoundClientFactory: (String sourceIpv4) {
      boundSource = sourceIpv4;
      return client;
    },
    epochSeconds: () => 1760000000,
    appPortalProbeUrl: '',
    appNetworkIdentityResolver: (_) async {
      resolverCalled = true;
      return _fixtureIdentity;
    },
    appAccountOptions: const AppAccountLoginOptions(enabled: false),
  );

  final result = await giWifi.login(
    baseUrl: 'http://10.100.100.2',
    profile: DeviceProfile.android,
    username: 'fixture-user',
    password: 'fixture-password',
    appUuid: '12345678-1234-1234-123456789abc',
    networkIdentity: _selectedWindowsAdapter.identity,
    onBindConflict: (_) async => false,
  );

  expect(resolverCalled, isFalse);
  expect(boundSource, '10.20.30.40');
  expect(result.session?.ip, '10.20.30.40');
  expect(decodedRequests, hasLength(2));
  expect(decodedRequests.every((fields) => fields['userIp'] == '10.20.30.40'), isTrue);
  expect(decodedRequests.last['userMac'], 'AA:BB:CC:DD:EE:01');
});
```

- [ ] **Step 3: Run the focused tests and verify RED**

Run:

```powershell
flutter test test/source_bound_http_client_test.dart test/giwifi_client_protocol_test.dart
```

Expected: compilation fails because the factory, constructor parameter, and `networkIdentity` login parameter do not exist.

- [ ] **Step 4: Implement the source-bound IO client**

Create `lib/giwifi/source_bound_http_client.dart`:

```dart
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'app_network_identity.dart';

http.Client createSourceBoundHttpClient(String sourceIpv4) {
  if (!isUsableIpv4Address(sourceIpv4)) {
    throw FormatException('无效的网卡 IPv4 地址: $sourceIpv4');
  }
  final sourceAddress = InternetAddress(sourceIpv4);
  final inner = HttpClient()
    ..findProxy = (_) => 'DIRECT'
    ..connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) {
      final host = proxyHost ?? uri.host;
      final port = proxyPort ?? uri.port;
      return Socket.startConnect(
        host,
        port,
        sourceAddress: sourceAddress,
      );
    };
  return IOClient(inner);
}
```

- [ ] **Step 5: Thread the identity through `GiWifiClient`**

Add:

```dart
typedef NetworkBoundClientFactory = http.Client Function(String sourceIpv4);
```

Add `NetworkBoundClientFactory? networkBoundClientFactory` to the constructor and default it to `createSourceBoundHttpClient`. Add optional `AppNetworkIdentity? networkIdentity` to `login`, `_loginWithWebPortal`, `_loginWithAppPortal`, and `_fetchAppPortalContext`.

Create the client through one helper:

```dart
http.Client _createClient(AppNetworkIdentity? networkIdentity) {
  if (networkIdentity == null) return _clientFactory();
  if (!isUsableIpv4Address(networkIdentity.userIp)) {
    throw const FormatException('所选网卡没有有效 IPv4 地址');
  }
  return _networkBoundClientFactory(networkIdentity.userIp.trim());
}
```

For App Portal context resolution use:

```dart
final identity = networkIdentity ??
    await _appNetworkIdentityResolver(portalUri);
```

This keeps every existing caller unchanged when no Windows selection is supplied.

- [ ] **Step 6: Run routing tests and verify GREEN**

Run:

```powershell
flutter test test/source_bound_http_client_test.dart test/giwifi_client_protocol_test.dart
```

Expected: validation, Web Portal binding, App Portal identity override, and all existing protocol tests pass.

- [ ] **Step 7: Commit**

```powershell
git add lib/giwifi/source_bound_http_client.dart lib/giwifi/giwifi_client.dart test/source_bound_http_client_test.dart test/giwifi_client_protocol_test.dart
git commit -m "feat: bind authentication to selected adapter"
```

### Task 5: Add the Windows selector, notice, and login validation

**Files:**
- Modify: `lib/app/home_page.dart`
- Modify: `test/widget_test.dart`

- [ ] **Step 1: Write failing widget tests**

Add imports for `package:http/http.dart`, `package:http/testing.dart`, `giwifi_client.dart`, `giwifi_models.dart`, and `windows_network_adapter.dart`. Define these fixtures:

```dart
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

Future<void> pumpHome(
  WidgetTester tester, {
  AppSettings settings = const AppSettings(),
  required Future<void> Function(AppSettings) onSettingsChanged,
  List<WindowsNetworkAdapter> adapters = const <WindowsNetworkAdapter>[
    wifi,
    ethernet,
  ],
  GiWifiClient? client,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: HomePage(
      settings: settings,
      onSettingsChanged: onSettingsChanged,
      showWindowsAdapterSelector: true,
      windowsAdapterLoader: () async => adapters,
      client: client,
    ),
  ));
  await tester.pumpAndSettle();
}
```

Add the selector and notice test:

```dart
testWidgets('shows the Windows adapter selector and usage notice', (tester) async {
  await pumpHome(tester, onSettingsChanged: (_) async {});

  expect(find.text('网络适配器'), findsOneWidget);
  expect(find.text('自动选择'), findsOneWidget);
  expect(
    find.text(
      '有线网络仅支持 Windows（电脑端）认证；'
      'Wi-Fi 可选择 Android、APad 或 Windows 终端认证。',
    ),
    findsOneWidget,
  );
});
```

Add the non-Windows presentation test; the notice remains useful on Android, but the selector is absent:

```dart
testWidgets('hides adapter selection outside Windows while keeping the notice', (
  tester,
) async {
  await tester.pumpWidget(MaterialApp(
    home: HomePage(
      settings: const AppSettings(),
      onSettingsChanged: (_) async {},
      showWindowsAdapterSelector: false,
    ),
  ));

  expect(find.text('网络适配器'), findsNothing);
  expect(
    find.textContaining('有线网络仅支持 Windows（电脑端）认证'),
    findsOneWidget,
  );
});
```

Add the persistence test:

```dart
testWidgets('persists the selected adapter ID', (tester) async {
  AppSettings? saved;
  await pumpHome(
    tester,
    onSettingsChanged: (settings) async => saved = settings,
  );

  await tester.tap(find.text('自动选择'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Intel Wi-Fi · Wi-Fi · 10.20.30.40').last);
  await tester.pumpAndSettle();

  expect(saved?.windowsAdapterId, '{WIFI}');
});
```

Add the missing persisted-adapter test:

```dart
testWidgets('clears a persisted adapter that disappeared', (tester) async {
  AppSettings? saved;
  await pumpHome(
    tester,
    settings: const AppSettings(windowsAdapterId: '{MISSING}'),
    adapters: const <WindowsNetworkAdapter>[wifi],
    onSettingsChanged: (settings) async => saved = settings,
  );

  expect(saved?.windowsAdapterId, isEmpty);
  expect(find.text('自动选择'), findsOneWidget);
  expect(find.textContaining('已切换为自动选择'), findsOneWidget);
});
```

Add the Ethernet/profile validation test. The injected client tracks whether any request escaped validation:

```dart
testWidgets('blocks mobile profiles on an explicitly selected Ethernet adapter', (
  tester,
) async {
  var requests = 0;
  final client = GiWifiClient(
    clientFactory: () => MockClient((http.Request request) async {
      requests++;
      return http.Response('', 500);
    }),
  );
  await pumpHome(
    tester,
    client: client,
    onSettingsChanged: (_) async {},
  );

  await tester.tap(find.text('自动选择'));
  await tester.pumpAndSettle();
  await tester.tap(
    find.text('Realtek Ethernet · 有线 · 10.10.0.8').last,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Android'));
  await tester.enterText(find.widgetWithText(TextFormField, '账号'), 'fixture');
  await tester.enterText(find.widgetWithText(TextFormField, '密码'), 'fixture');
  await tester.tap(find.widgetWithText(FilledButton, '登录'));
  await tester.pumpAndSettle();

  expect(requests, 0);
  expect(find.text('有线网络只能使用 Windows 终端认证'), findsWidgets);
});
```

Update the pre-existing basic rendering test to pass `showWindowsAdapterSelector: false`, keeping it platform-independent.

- [ ] **Step 2: Run widget tests and verify RED**

Run: `flutter test test/widget_test.dart test/device_profile_test.dart`

Expected: compilation fails because the selector dependencies and text are absent.

- [ ] **Step 3: Add injectable Windows adapter state**

In `HomePage`, add optional constructor fields:

```dart
final WindowsNetworkAdapterLoader? windowsAdapterLoader;
final bool? showWindowsAdapterSelector;
final GiWifiClient? client;
```

In state, initialize the client and loader in `initState`, seed `_selectedAdapterId` from settings, and start `_refreshWindowsAdapters`. Track:

```dart
List<WindowsNetworkAdapter> _windowsAdapters = const [];
String _selectedAdapterId = '';
bool _isLoadingAdapters = false;
bool _adapterEnumerationSucceeded = false;
String _adapterError = '';
```

The Windows-only decision is `widget.showWindowsAdapterSelector ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows)`.

Use these initialization and refresh methods:

```dart
@override
void initState() {
  super.initState();
  _client = widget.client ?? GiWifiClient();
  _windowsAdapterLoader = widget.windowsAdapterLoader ??
      const WindowsNetworkAdapterService().listAdapters;
  _selectedAdapterId = widget.settings.windowsAdapterId;
  _accountController.text = widget.settings.savedAccount;
  _passwordController.text = widget.settings.savedPassword;
  _selectedProfile = widget.settings.savedProfile;
  if (_showWindowsAdapterSelector) {
    unawaited(_refreshWindowsAdapters(clearMissingSelection: true));
  }
}

bool get _showWindowsAdapterSelector =>
    widget.showWindowsAdapterSelector ??
    (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows);

Future<List<WindowsNetworkAdapter>?> _refreshWindowsAdapters({
  required bool clearMissingSelection,
}) async {
  if (!_showWindowsAdapterSelector) return const <WindowsNetworkAdapter>[];
  if (mounted) {
    setState(() {
      _isLoadingAdapters = true;
      _adapterError = '';
    });
  }
  try {
    final adapters = sortWindowsNetworkAdapters(await _windowsAdapterLoader());
    final missing = _selectedAdapterId.isNotEmpty &&
        findWindowsNetworkAdapter(adapters, _selectedAdapterId) == null;
    if (!mounted) return adapters;
    setState(() {
      _windowsAdapters = adapters;
      _adapterEnumerationSucceeded = true;
      _isLoadingAdapters = false;
      if (missing && clearMissingSelection) {
        _selectedAdapterId = '';
        _adapterError = '上次选择的网卡不可用，已切换为自动选择';
      }
    });
    if (missing && clearMissingSelection) {
      await widget.onSettingsChanged(
        widget.settings.copyWith(windowsAdapterId: ''),
      );
    }
    return adapters;
  } on Object catch (error) {
    if (mounted) {
      setState(() {
        _isLoadingAdapters = false;
        _adapterEnumerationSucceeded = false;
        _adapterError = '读取网络适配器失败: $error';
      });
    }
    return null;
  }
}

Future<void> _selectWindowsAdapter(String? id) async {
  final nextId = id ?? '';
  setState(() => _selectedAdapterId = nextId);
  await widget.onSettingsChanged(
    widget.settings.copyWith(windowsAdapterId: nextId),
  );
}
```

Use `clearMissingSelection: false` for the pre-login refresh so a selected adapter disappearing during the login attempt produces an error instead of silently switching adapters.

- [ ] **Step 4: Render the selector and permanent notice**

Insert the notice immediately below the login-card description in a tinted `Container` with `Icons.info_outline`. Insert the selector between the password field and terminal segmented button on Windows.

Use `DropdownButtonFormField<String>` keyed by the current ID, with:

```dart
const DropdownMenuItem<String>(
  value: '',
  child: Text('自动选择'),
)
```

Adapter labels must be generated as:

```dart
String _adapterLabel(WindowsNetworkAdapter adapter) =>
    '${adapter.name} · ${adapter.typeLabel}${adapter.isVirtual ? "（虚拟）" : ""} · ${adapter.ipv4}';
```

Add an adjacent refresh icon. Disable both controls while loading or authenticating. Show the enumeration error or no-adapter message below the control without removing the automatic option.

Disable the login button only when enumeration succeeded and returned an empty list. An enumeration exception keeps login enabled so the existing automatic resolver remains usable:

```dart
final hasNoWindowsAdapters = _showWindowsAdapterSelector &&
    _adapterEnumerationSucceeded &&
    _windowsAdapters.isEmpty;

onPressed: _isSubmitting || hasNoWindowsAdapters ? null : _submitLogin,
```

- [ ] **Step 5: Resolve and validate the adapter before login**

At the start of `_submitLogin`, refresh the list when the Windows selector is enabled and call this helper. If enumeration throws it returns `null`, preserving the legacy automatic resolver. A successful empty list stops login with `未发现可用的 IPv4 网络适配器`.

```dart
WindowsNetworkAdapter? _adapterForLogin(
  List<WindowsNetworkAdapter>? adapters,
) {
  if (adapters == null) return null;
  if (adapters.isEmpty) {
    throw const FormatException('未发现可用的 IPv4 网络适配器');
  }
  if (_selectedAdapterId.isNotEmpty) {
    final selected = findWindowsNetworkAdapter(adapters, _selectedAdapterId);
    if (selected == null) {
      throw const FormatException('所选网络适配器已不可用，请刷新后重新选择');
    }
    return selected;
  }
  for (final adapter in adapters) {
    if (!adapter.isVirtual) return adapter;
  }
  return adapters.first;
}
```

Before any request:

```dart
if (adapter?.kind == WindowsNetworkAdapterKind.ethernet &&
    _selectedProfile != DeviceProfile.windows) {
  _replaceLogs(const <String>[
    '[ERROR] 有线网络只能使用 Windows 终端认证',
  ]);
  setState(() {
    _connectionState = _ConnectionViewState.failed;
    _statusMessage = '有线网络只能使用 Windows 终端认证';
  });
  return;
}
```

Log the resolved adapter name/IP and pass `networkIdentity: adapter?.identity` to `_client.login`. Persist every explicit selection immediately through `onSettingsChanged`; use `''` for automatic.

- [ ] **Step 6: Run widget tests and verify GREEN**

Run: `flutter test test/widget_test.dart test/device_profile_test.dart`

Expected: selector, notice, persistence, fallback, validation, and existing narrow-layout tests all pass without overflow.

- [ ] **Step 7: Commit**

```powershell
git add lib/app/home_page.dart test/widget_test.dart test/device_profile_test.dart
git commit -m "feat: add Windows adapter selector"
```

### Task 6: Cross-platform regression and release-build verification

**Files:**
- Modify only files required to fix failures caused by Tasks 1–5.

- [ ] **Step 1: Format and inspect the diff**

Run:

```powershell
dart format lib test
git diff --check
git status --short
```

Expected: formatter completes, `git diff --check` is silent, and only planned files are modified.

- [ ] **Step 2: Run static analysis and all automated tests**

Run:

```powershell
flutter analyze
flutter test
```

Expected: `No issues found!` and `All tests passed!` with only the three existing opt-in live tests skipped.

- [ ] **Step 3: Build Windows Release**

Run:

```powershell
flutter build windows --release --no-pub
```

Expected: `build/windows/x64/runner/Release/xgiwifi.exe` exists and the runner links the adapter channel.

- [ ] **Step 4: Verify the actual Windows channel manually**

Launch the Release executable, confirm the selector lists the machine's active Ethernet/Wi-Fi adapters with IPv4 addresses, select one, restart the app, and confirm the same stable adapter is selected. Confirm virtual adapters are marked and sorted last. Do not use or display real account credentials during this check.

- [ ] **Step 5: Verify Android remains unchanged**

Run:

```powershell
$env:FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn'
flutter build apk --release --no-pub
```

Expected: Android release APK builds successfully and the Windows-only selector is excluded by the runtime platform check.

- [ ] **Step 6: Commit verification-only fixes, if any**

If formatting or a regression fix changed files, commit them:

```powershell
git add lib test windows
git commit -m "test: verify Windows adapter selection"
```

If no files changed, do not create an empty commit.
