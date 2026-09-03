import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:xgiwifi/app/app_settings.dart';
import 'package:xgiwifi/app/home_page.dart';
import 'package:xgiwifi/giwifi/giwifi_client.dart';
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
  GiWifiClient? client,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: HomePage(
        settings: settings,
        onSettingsChanged: onSettingsChanged,
        showWindowsAdapterSelector: true,
        windowsAdapterLoader: () async => adapters,
        client: client,
      ),
    ),
  );
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
}
