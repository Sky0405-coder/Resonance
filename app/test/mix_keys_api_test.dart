import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/api.dart';

void main() {
  test('mixKeys parses nullable keys and numeric BPMs, authenticating and chunking at 500', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final chunks = <List<String>>[];
    server.listen((request) async {
      expect(request.uri.path, '/api/mixpoints/keys');
      expect(request.headers.value(HttpHeaders.authorizationHeader), 'Bearer token');
      final ids = request.uri.queryParameters['ids']!.split(',');
      chunks.add(ids);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          for (final id in ids)
            id: switch (int.parse(id) % 4) {
              0 => {'key': '8A', 'bpm': 120},
              1 => {'key': '9B', 'bpm': 123.5},
              2 => {'key': null, 'bpm': null},
              _ => null,
            },
        }),
      );
      await request.response.close();
    });
    final api = ApiClient('http://${server.address.address}:${server.port}', 'token');
    expect(await api.mixKeys([]), isEmpty);
    expect(chunks, isEmpty);
    final ids = List.generate(1001, (i) => '$i');
    final result = await api.mixKeys(ids);
    expect(chunks.map((chunk) => chunk.length), [500, 500, 1]);
    expect(chunks.expand((chunk) => chunk), ids);
    expect(result, hasLength(1001));
    expect(result['0'], (key: '8A', bpm: 120.0));
    expect(result['1'], (key: '9B', bpm: 123.5));
    expect(result['2'], (key: null, bpm: null));
    expect(result['3'], isNull);
    expect(result['1000'], (key: '8A', bpm: 120.0));
  });
}
