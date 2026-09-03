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
