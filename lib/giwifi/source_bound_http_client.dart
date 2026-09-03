import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'app_network_identity.dart';

http.Client createSourceBoundHttpClient(String sourceIpv4) {
  final normalizedSourceIpv4 = sourceIpv4.trim();
  if (!isUsableIpv4Address(normalizedSourceIpv4)) {
    throw FormatException('无效的网卡 IPv4 地址: $sourceIpv4');
  }

  final sourceAddress = InternetAddress(normalizedSourceIpv4);
  final innerClient = HttpClient();
  innerClient.findProxy = (_) => 'DIRECT';
  innerClient.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) {
    return Socket.startConnect(
      proxyHost ?? uri.host,
      proxyPort ?? uri.port,
      sourceAddress: sourceAddress,
    );
  };

  return IOClient(innerClient);
}
