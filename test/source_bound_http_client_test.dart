import 'dart:async';
import 'dart:io';

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

  test('creates a source-bound plain socket task for HTTP', () async {
    final pendingSocket = Completer<Socket>();
    var secureUpgradeCalled = false;
    Object? connectedHost;
    int? connectedPort;
    Object? connectedSource;
    final rawTask = ConnectionTask.fromSocket<Socket>(
      pendingSocket.future,
      () {},
    );
    final sourceAddress = InternetAddress('10.20.30.40');

    final task = await startSourceBoundConnection(
      uri: Uri.parse('http://portal.example/path'),
      sourceAddress: sourceAddress,
      socketStarter: (Object host, int port, {Object? sourceAddress}) async {
        connectedHost = host;
        connectedPort = port;
        connectedSource = sourceAddress;
        return rawTask;
      },
      secureSocket: (Future<Socket> socket, String host) {
        secureUpgradeCalled = true;
        return socket;
      },
    );

    expect(task, same(rawTask));
    expect(connectedHost, 'portal.example');
    expect(connectedPort, 80);
    expect(connectedSource, same(sourceAddress));
    expect(secureUpgradeCalled, isFalse);
  });

  test('upgrades a bound HTTPS socket and preserves cancellation', () async {
    final pendingSocket = Completer<Socket>();
    var secureUpgradeCalled = false;
    var rawTaskCancelled = false;
    final rawTask = ConnectionTask.fromSocket<Socket>(
      pendingSocket.future,
      () => rawTaskCancelled = true,
    );

    final task = await startSourceBoundConnection(
      uri: Uri.parse('https://portal.example/path'),
      sourceAddress: InternetAddress('10.20.30.40'),
      socketStarter: (Object host, int port, {Object? sourceAddress}) async {
        expect(host, 'portal.example');
        expect(port, 443);
        expect(sourceAddress, InternetAddress('10.20.30.40'));
        return rawTask;
      },
      secureSocket: (Future<Socket> socket, String host) {
        secureUpgradeCalled = true;
        expect(host, 'portal.example');
        return socket;
      },
    );

    expect(task, isNot(same(rawTask)));
    expect(secureUpgradeCalled, isTrue);

    task.cancel();
    expect(rawTaskCancelled, isTrue);
  });
}
