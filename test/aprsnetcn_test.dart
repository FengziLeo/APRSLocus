/// APRSNETCN 的 24 小时台站接口：解析那一层的回归测试。
///
/// 为什么钉在 CI：这一层全是「错了也不报错」的活。
///   * 服务器给的时间是**不带偏移的北京时间**（`2026-10-17T23:44:01`），
///     直接交给 `DateTime.tryParse` 会按本机时区解释 —— 编译过、analyze 全绿、
///     界面上也能显示，只是出了国门「多久前听到」差 8 小时，在线离线判反。
///   * 缺坐标的台站若带着 0,0 进列表，地图会在几内亚湾堆出一片假台站。
///   * 符号表字段是嵌套的 `{"table","code"}`，当成字符串取就会全变 `/`。
/// 这三条都只能靠测试钉住。
library;

import 'package:aprslocus/aprsnetcn.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> row({
  Object? call = 'BG7LZQ-9',
  Object? lat = 22.5431,
  Object? lon = 114.0579,
  Object? lastSeen = '2026-10-17T23:44:01',
  Object? symbol = const {'table': '/', 'code': '>'},
  Object? speed,
  Object? course,
  Object? alt,
  Object? comment,
  Object? packets,
}) =>
    {
      'call': call,
      'lat': lat,
      'lon': lon,
      'last_seen': lastSeen,
      'symbol': symbol,
      'speed': speed,
      'course': course,
      'alt': alt,
      'comment': comment,
      'packets': packets,
    };

void main() {
  test('正常一条：坐标、符号、时间都解析出来', () {
    final s = AcnStation.fromJson(row(
      speed: 12.5,
      course: 87,
      alt: 35,
      comment: 'in the car',
      packets: 7,
    ));
    expect(s, isNotNull);
    expect(s!.call, 'BG7LZQ-9');
    expect(s.lat, closeTo(22.5431, 1e-9));
    expect(s.lng, closeTo(114.0579, 1e-9));
    expect(s.symbolTable, '/');
    expect(s.symbol, '>');
    expect(s.speed, closeTo(12.5, 1e-9));
    expect(s.course, closeTo(87, 1e-9));
    expect(s.alt, closeTo(35, 1e-9));
    expect(s.comment, 'in the car');
    expect(s.packets, 7);
  });

  test('不带偏移的时间按北京时间解释（不是本机时区）', () {
    // 2026-10-17T23:44:01 +08:00 == 2026-10-17T15:44:01Z
    final s = AcnStation.fromJson(row());
    expect(s!.lastSeen.toUtc(),
        DateTime.utc(2026, 10, 17, 15, 44, 1));
  });

  test('带偏移的时间按偏移走，不再补 +08:00', () {
    final s = AcnStation.fromJson(row(lastSeen: '2026-10-17T15:44:01Z'));
    expect(s!.lastSeen.toUtc(), DateTime.utc(2026, 10, 17, 15, 44, 1));
    final t = AcnStation.fromJson(row(lastSeen: '2026-10-17T15:44:01+02:00'));
    expect(t!.lastSeen.toUtc(), DateTime.utc(2026, 10, 17, 13, 44, 1));
  });

  test('缺坐标 / 缺时间 / 空呼号 / 非 map：整条丢掉，不留 0,0', () {
    expect(AcnStation.fromJson(row(lat: null)), isNull);
    expect(AcnStation.fromJson(row(lon: 'nope')), isNull);
    expect(AcnStation.fromJson(row(lastSeen: '')), isNull);
    expect(AcnStation.fromJson(row(call: '  ')), isNull);
    expect(AcnStation.fromJson('BG7LZQ-9'), isNull);
    expect(AcnStation.fromJson(null), isNull);
  });

  test('呼号统一大写，缺符号时回落到 /，缺 packets 记 0', () {
    final s = AcnStation.fromJson(
        row(call: ' bg7lzq-9 ', symbol: null));
    expect(s!.call, 'BG7LZQ-9');
    expect(s.symbolTable, '/');
    expect(s.symbol, '/');
    expect(s.packets, 0);
    expect(s.comment, '');
  });

  test('数值可能是字符串（服务器改了序列化也不该整条丢）', () {
    final s = AcnStation.fromJson(
        row(lat: '22.5', lon: '114.0', speed: '3.2'));
    expect(s!.lat, closeTo(22.5, 1e-9));
    expect(s.speed, closeTo(3.2, 1e-9));
  });
}
