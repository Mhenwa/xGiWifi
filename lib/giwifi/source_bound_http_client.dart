import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'app_network_identity.dart';

typedef SourceBoundSocketStarter =
    Future<ConnectionTask<Socket>> Function(
      Object host,
      int port, {
      Object? sourceAddress,
    });
typedef SourceBoundSecureSocket =
    Future<Socket> Function(Future<Socket> socket, String host);

Future<ConnectionTask<Socket>> _startSocket(
  Object host,
  int port, {
  Object? sourceAddress,
}) => Socket.startConnect(host, port, sourceAddress: sourceAddress);

Future<Socket> _secureSocket(Future<Socket> socketFuture, String host) async {
  final socket = await socketFuture;
  try {
    return await SecureSocket.secure(socket, host: host);
  } on Object {
    socket.destroy();
    rethrow;
  }
}

Future<ConnectionTask<Socket>> startSourceBoundConnection({
  required Uri uri,
  required InternetAddress sourceAddress,
  String? proxyHost,
  int? proxyPort,
  SourceBoundSocketStarter socketStarter = _startSocket,
  SourceBoundSecureSocket secureSocket = _secureSocket,
}) async {
  final rawTask = await socketStarter(
    proxyHost ?? uri.host,
    proxyPort ?? uri.port,
    sourceAddress: sourceAddress,
  );
  if (proxyHost != null || uri.scheme.toLowerCase() != 'https') {
    return rawTask;
  }

  Socket? activeSocket;
  final trackedRawSocket = rawTask.socket.then<Socket>((Socket socket) {
    activeSocket = socket;
    return socket;
  });
  final securedSocket = secureSocket(trackedRawSocket, uri.host).then<Socket>((
    Socket socket,
  ) {
    activeSocket = socket;
    return socket;
  });
  return ConnectionTask.fromSocket<Socket>(securedSocket, () {
    activeSocket?.destroy();
    rawTask.cancel();
  });
}

http.Client createSourceBoundHttpClient(String sourceIpv4) {
  final normalizedSourceIpv4 = sourceIpv4.trim();
  if (!isUsableIpv4Address(normalizedSourceIpv4)) {
    throw FormatException('无效的网卡 IPv4 地址: $sourceIpv4');
  }

  final sourceAddress = InternetAddress(normalizedSourceIpv4);
  final innerClient = HttpClient();
  innerClient.findProxy = (_) => 'DIRECT';
  innerClient.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) {
    return startSourceBoundConnection(
      uri: uri,
      sourceAddress: sourceAddress,
      proxyHost: proxyHost,
      proxyPort: proxyPort,
    );
  };

  return IOClient(innerClient);
}
