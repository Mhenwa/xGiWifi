import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:xgiwifi/app/app_settings.dart';
import 'package:xgiwifi/app/home_page.dart';
import 'package:xgiwifi/giwifi/app_network_identity.dart';
import 'package:xgiwifi/giwifi/giwifi_client.dart';
import 'package:xgiwifi/giwifi/giwifi_models.dart';
import 'package:xgiwifi/giwifi/windows_network_adapter.dart';

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
  WindowsNetworkAdapterLoader? adapterLoader,
  GiWifiClient? client,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: HomePage(
        settings: settings,
        onSettingsChanged: onSettingsChanged,
        showWindowsAdapterSelector: true,
        windowsAdapterLoader: adapterLoader ?? () async => adapters,
        client: client,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> selectAdapter(
  WidgetTester tester,
  String currentLabel,
  String nextLabel,
) async {
  final currentSelection = find.text(currentLabel);
  await tester.ensureVisible(currentSelection);
  await tester.pumpAndSettle();
  await tester.tap(currentSelection);
  await tester.pumpAndSettle();
  await tester.tap(find.text(nextLabel).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('home page renders main sections', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          settings: const AppSettings(),
          onSettingsChanged: (_) async {},
          showWindowsAdapterSelector: false,
        ),
      ),
    );

    expect(find.text('xGiWifi'), findsOneWidget);
    expect(find.text('账号登录'), findsOneWidget);
    expect(find.text('日志'), findsOneWidget);
  });

  testWidgets('shows the Windows adapter selector and usage notice', (
    WidgetTester tester,
  ) async {
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

  testWidgets(
    'hides adapter selection outside Windows while keeping the notice',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(
            settings: const AppSettings(),
            onSettingsChanged: (_) async {},
            showWindowsAdapterSelector: false,
          ),
        ),
      );

      expect(find.text('网络适配器'), findsNothing);
      expect(find.textContaining('有线网络仅支持 Windows（电脑端）认证'), findsOneWidget);
    },
  );

  testWidgets('persists the selected adapter ID', (WidgetTester tester) async {
    AppSettings? saved;
    await pumpHome(
      tester,
      onSettingsChanged: (AppSettings settings) async => saved = settings,
    );

    final automaticSelection = find.text('自动选择');
    await tester.ensureVisible(automaticSelection);
    await tester.pumpAndSettle();
    await tester.tap(automaticSelection);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Intel Wi-Fi · Wi-Fi · 10.20.30.40').last);
    await tester.pumpAndSettle();

    expect(saved?.windowsAdapterId, '{WIFI}');
  });

  testWidgets('clears a persisted adapter that disappeared', (
    WidgetTester tester,
  ) async {
    AppSettings? saved;
    await pumpHome(
      tester,
      settings: const AppSettings(windowsAdapterId: '{MISSING}'),
      adapters: const <WindowsNetworkAdapter>[wifi],
      onSettingsChanged: (AppSettings settings) async => saved = settings,
    );

    expect(saved?.windowsAdapterId, isEmpty);
    expect(find.text('自动选择'), findsOneWidget);
    expect(find.textContaining('已切换为自动选择'), findsOneWidget);
  });

  testWidgets(
    'blocks mobile profiles on an explicitly selected Ethernet adapter',
    (WidgetTester tester) async {
      var requests = 0;
      final mockClient = MockClient((http.Request request) async {
        requests++;
        return http.Response('', 500);
      });
      final client = GiWifiClient(
        clientFactory: () => mockClient,
        networkBoundClientFactory: (_) => mockClient,
      );
      await pumpHome(tester, client: client, onSettingsChanged: (_) async {});

      final automaticSelection = find.text('自动选择');
      await tester.ensureVisible(automaticSelection);
      await tester.pumpAndSettle();
      await tester.tap(automaticSelection);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Realtek Ethernet · 有线 · 10.10.0.8').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Android'));
      await tester.enterText(
        find.widgetWithText(TextFormField, '账号'),
        'fixture',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '密码'),
        'fixture',
      );
      final loginButton = find.widgetWithText(FilledButton, '登录');
      await tester.ensureVisible(loginButton);
      await tester.tap(loginButton);
      await tester.pumpAndSettle();

      expect(requests, 0);
      expect(find.text('有线网络只能使用 Windows 终端认证'), findsWidgets);
    },
  );

  testWidgets('automatic mode keeps legacy routing for mobile profiles', (
    WidgetTester tester,
  ) async {
    var unboundClients = 0;
    var boundClients = 0;
    var requests = 0;
    final mockClient = MockClient((http.Request request) async {
      requests++;
      return http.Response(
        jsonEncode(<String, Object?>{
          'resultCode': 1,
          'resultMsg': 'expected test stop',
          'data': <String, Object?>{},
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final client = GiWifiClient(
      clientFactory: () {
        unboundClients++;
        return mockClient;
      },
      networkBoundClientFactory: (_) {
        boundClients++;
        return mockClient;
      },
      appPortalProbeUrl: '',
      appAccountOptions: const AppAccountLoginOptions(enabled: false),
      appNetworkIdentityResolver: (_) async => const AppNetworkIdentity(
        userIp: '10.10.0.8',
        userMac: 'AA:BB:CC:DD:EE:02',
        interfaceName: 'Ethernet',
        gatewayIp: '10.10.0.1',
      ),
    );
    await pumpHome(
      tester,
      settings: const AppSettings(
        savedAccount: 'fixture',
        savedPassword: 'fixture',
        savedProfile: DeviceProfile.android,
      ),
      adapters: const <WindowsNetworkAdapter>[ethernet],
      client: client,
      onSettingsChanged: (_) async {},
    );

    final loginButton = find.widgetWithText(FilledButton, '登录');
    await tester.ensureVisible(loginButton);
    await tester.tap(loginButton);
    await tester.pumpAndSettle();

    expect(unboundClients, 1);
    expect(boundClients, 0);
    expect(requests, greaterThan(0));
    expect(find.text('有线网络只能使用 Windows 终端认证'), findsNothing);
  });

  testWidgets('fails closed when an explicit adapter cannot be enumerated', (
    WidgetTester tester,
  ) async {
    var requests = 0;
    final mockClient = MockClient((http.Request request) async {
      requests++;
      return http.Response('', 500);
    });
    final client = GiWifiClient(
      clientFactory: () => mockClient,
      networkBoundClientFactory: (_) => mockClient,
    );
    await pumpHome(
      tester,
      settings: const AppSettings(
        savedAccount: 'fixture',
        savedPassword: 'fixture',
        windowsAdapterId: '{ETHERNET}',
      ),
      adapterLoader: () async => throw StateError('enumeration failed'),
      client: client,
      onSettingsChanged: (_) async {},
    );

    final loginButton = find.widgetWithText(FilledButton, '登录');
    await tester.ensureVisible(loginButton);
    await tester.tap(loginButton);
    await tester.pumpAndSettle();

    expect(requests, 0);
    expect(find.text('无法验证所选网络适配器，请刷新后重试'), findsWidgets);
  });

  testWidgets('locks preflight inputs and ignores duplicate login taps', (
    WidgetTester tester,
  ) async {
    final settingsSave = Completer<void>();
    var settingsSaves = 0;
    var adapterLoads = 0;
    String? requestedPath;
    final mockClient = MockClient((http.Request request) async {
      requestedPath = request.url.path;
      return http.Response('', 500);
    });
    final client = GiWifiClient(
      clientFactory: () => throw StateError('unbound client used'),
      networkBoundClientFactory: (_) => mockClient,
    );
    await pumpHome(
      tester,
      settings: const AppSettings(
        savedAccount: 'fixture',
        savedPassword: 'fixture',
        savedProfile: DeviceProfile.windows,
        windowsAdapterId: '{ETHERNET}',
      ),
      adapterLoader: () async {
        adapterLoads++;
        return const <WindowsNetworkAdapter>[ethernet];
      },
      client: client,
      onSettingsChanged: (_) {
        settingsSaves++;
        return settingsSave.future;
      },
    );

    final loginButton = find.widgetWithText(FilledButton, '登录');
    await tester.ensureVisible(loginButton);
    await tester.tap(loginButton);
    await tester.pump();

    expect(settingsSaves, 1);
    expect(adapterLoads, 2);
    expect(
      tester
          .widget<SegmentedButton<DeviceProfile>>(
            find.byType(SegmentedButton<DeviceProfile>),
          )
          .onSelectionChanged,
      isNull,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );

    await tester.tap(find.text('Android'), warnIfMissed: false);
    await tester.tap(find.byType(FilledButton), warnIfMissed: false);
    await tester.pump();
    expect(settingsSaves, 1);
    expect(adapterLoads, 2);

    settingsSave.complete();
    await tester.pumpAndSettle();

    expect(requestedPath, '/gportal/web/login');
  });

  testWidgets('serializes adapter saves and keeps the newest selection', (
    WidgetTester tester,
  ) async {
    final firstSave = Completer<void>();
    final startedSaves = <String>[];
    AppSettings? lastSaved;
    await pumpHome(
      tester,
      onSettingsChanged: (AppSettings settings) {
        startedSaves.add(settings.windowsAdapterId);
        if (startedSaves.length == 1) {
          return firstSave.future;
        }
        lastSaved = settings;
        return Future<void>.value();
      },
    );

    await selectAdapter(tester, '自动选择', 'Intel Wi-Fi · Wi-Fi · 10.20.30.40');
    await selectAdapter(
      tester,
      'Intel Wi-Fi · Wi-Fi · 10.20.30.40',
      'Realtek Ethernet · 有线 · 10.10.0.8',
    );

    expect(startedSaves, <String>['{WIFI}']);
    firstSave.completeError(StateError('first save failed'));
    await tester.pumpAndSettle();

    expect(startedSaves, <String>['{WIFI}', '{ETHERNET}']);
    expect(lastSaved?.windowsAdapterId, '{ETHERNET}');
    expect(find.text('Realtek Ethernet · 有线 · 10.10.0.8'), findsOneWidget);
  });
}
