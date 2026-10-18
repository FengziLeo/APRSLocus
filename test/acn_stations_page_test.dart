// APRSNETCN 的 24 小时台站是分页拉的。
//
// 用户报「每次同步只能 2000 人」，根因是这里把 limit 写死成 2000 又只请一次。
// 这种错编译能过、analyze 全绿，只表现成「地图上少了一大半人」，只能用测试钉住。
//
// 用一个本机的小 HTTP 服务当服务器：4500 台，页大小 2000，看它是不是
// 2000 → 2000 → 500 拿完，而且 offset 一路往后走。

import 'dart:convert';
import 'dart:io';

import 'package:aprslocus/aprsnetcn.dart';
import 'package:flutter_test/flutter_test.dart';

const int _total = 4500;

Map<String, Object?> _row(int index) => {
      'call': 'BG$index',
      'last_seen': '2026-10-18T00:00:00',
      'lat': 30.0 + index / 100000,
      'lon': 107.0,
      'symbol': {'table': '/', 'code': '>'},
      'packets': 1,
    };

void main() {
  HttpServer? server;
  var base = '';
  final pages = <int>[];
  var logins = 0;

  setUp(() async {
    pages.clear();
    logins = 0;
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server = s;
    base = 'http://127.0.0.1:${s.port}';
    s.listen((request) async {
      final response = request.response;
      response.headers.contentType = ContentType.json;
      if (request.uri.path == '/api/v1/login') {
        logins++;
        response.write(jsonEncode({'token': 'tok-$logins'}));
        await response.close();
        return;
      }
      final query = request.uri.queryParameters;
      final limit = int.parse(query['limit'] ?? '500');
      final offset = int.parse(query['offset'] ?? '0');
      final size = query['window'] == '1h' ? 500 : _total;
      pages.add(offset);
      final rows = <Map<String, Object?>>[
        for (var i = offset; i < size && i < offset + limit; i++) _row(i),
      ];
      response.write(jsonEncode({
        'count': rows.length,
        'total': size,
        'offset': offset,
        'limit': limit,
        'stations': rows,
      }));
      await response.close();
    });
  });

  tearDown(() async {
    await server?.close(force: true);
    server = null;
  });

  test('超过一页的台站会翻页拿完', () async {
    final client = AcnClient(base: base);
    final rows = await client.stations(account: 'bg7lzq', password: 'pw');
    expect(rows.length, _total);
    expect(pages, [0, 2000, 4000]);
    expect(logins, 1);
    expect(rows.last.call, 'BG4499');
  });

  test('一页就够时只请一次', () async {
    final client = AcnClient(base: base);
    // 1 小时窗口里只有 500 台，少于页大小 2000，不该再问第二遍。
    final rows = await client.stations(
      account: 'bg7lzq',
      password: 'pw',
      hours: 1,
    );
    expect(rows.length, 500);
    expect(pages, [0]);
  });

  test('翻页时不会重复也不会漏', () async {
    final client = AcnClient(base: base);
    final rows = await client.stations(account: 'bg7lzq', password: 'pw');
    final calls = rows.map((row) => row.call).toList();
    expect(calls.toSet().length, calls.length);
    expect(calls.first, 'BG0');
    expect(calls[1999], 'BG1999');
    expect(calls[2000], 'BG2000');
  });
}
