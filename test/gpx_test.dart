/// 历史轨迹导出 GPX 的回归测试。
///
/// 用户要求：历史轨迹页能导出 GPX，范围给「一天 / 1 周 / 1 个月 / 1 年 / 自定义」。
///
/// 为什么钉在 CI：GPX 是**给别人读的文件**（Strava / Garmin / Google Earth），
/// 写错了在这里一点报错都没有 —— 编译过、analyze 全绿、应用里也「导出成功」，
/// 只有导进第三方之后才看得见：时间没带 Z（时区错 8 小时）、海拔补 0（一条贴着
/// 海平面的线）、断档不断段（凭空多出一条跨越几百公里的直线）。所以把这几条
/// 意图逐字钉住。
library;

import 'package:aprslocus/gpx.dart';
import 'package:aprslocus/track_log.dart';
import 'package:flutter_test/flutter_test.dart';

TrackLogPoint pt(
  int minute, {
  double lat = 39.9075,
  double lng = 116.3972,
  double? alt,
  int? hr,
  double speed = 0,
}) =>
    TrackLogPoint(
      lat: lat,
      lng: lng,
      time: DateTime(2026, 10, 16, 8, 0).add(Duration(minutes: minute)),
      speedKmh: speed,
      alt: alt,
      hr: hr,
    );

void main() {
  test('文件名：单天用连字符，跨天用下划线连起来', () {
    expect(Gpx.fileName('2026-10-16', '2026-10-16'),
        'APRSLocus-2026-10-16.gpx');
    expect(Gpx.fileName('2026-10-10', '2026-10-16'),
        'APRSLocus-2026-10-10_2026-10-16.gpx');
  });

  test('一天一条 trk，点落在 trkseg 里', () {
    final xml = Gpx.encode([
      DayTrack('2026-10-16', [pt(0), pt(1)]),
      DayTrack('2026-10-15', [pt(0), pt(1), pt(2)]),
    ], now: DateTime(2026, 10, 16, 12));
    expect(xml.startsWith('<?xml version="1.0" encoding="UTF-8"?>'), isTrue);
    expect(xml.trimRight().endsWith('</gpx>'), isTrue);
    expect(xml.contains('xmlns="http://www.topografix.com/GPX/1/1"'), isTrue);
    expect('trk>'.allMatches(xml).length, 4,
        reason: '两天 = 两个 <trk>，加上两个 </trk>');
    expect('<trkseg>'.allMatches(xml).length, 2);
    expect('<trkpt'.allMatches(xml).length, 5);
    // 写出的顺序按日期升序，与传进来的顺序无关
    expect(xml.indexOf('<name>2026-10-15</name>'),
        lessThan(xml.indexOf('<name>2026-10-16</name>')));
  });

  test('时间带 Z、不带毫秒（本地时间必须换算成 UTC）', () {
    final xml = Gpx.encode([DayTrack('2026-10-16', [pt(0)])]);
    final iso = RegExp(r'<time>(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)</time>');
    expect(iso.allMatches(xml).length, 2,
        reason: 'metadata 与 trkpt 两处都必须是 UTC 的 ISO 8601（不带毫秒）');
    final utc = DateTime(2026, 10, 16, 8, 0).toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final want = '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-'
        '${two(utc.day)}T${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}Z';
    expect(xml.contains('<time>$want</time>'), isTrue,
        reason: '轨迹点的时间必须按 UTC 写出（本地时间直接写就是时区错）');
  });

  test('坐标固定六位小数（换成科学计数法/本地化小数点第三方直接读不了）', () {
    final xml = Gpx.encode([
      DayTrack('2026-10-16', [
        TrackLogPoint(lat: 39.9, lng: -116.4, time: DateTime(2026, 10, 16, 8)),
      ]),
    ]);
    expect(xml.contains('<trkpt lat="39.900000" lon="-116.400000">'), isTrue);
  });

  test('海拔与心率只在真有读数时写', () {
    final bare = Gpx.encode([
      DayTrack('2026-10-16', [pt(0)]),
    ]);
    expect(bare.contains('<ele>'), isFalse);
    expect(bare.contains('gpxtpx:hr'), isFalse);
    // hr 写 0 = 「那一刻没有读数」，也不能写成 0 bpm
    final zero = Gpx.encode([
      DayTrack('2026-10-16', [pt(0, hr: 0)]),
    ]);
    expect(zero.contains('gpxtpx:hr'), isFalse);

    final full = Gpx.encode([
      DayTrack('2026-10-16', [pt(0, alt: 43.26, hr: 142)]),
    ]);
    expect(full.contains('<ele>43.3</ele>'), isTrue,
        reason: '海拔一位小数就够（GPS 垂直精度远不止 0.1 m）');
    expect(full.contains('<gpxtpx:hr>142</gpxtpx:hr>'), isTrue);
  });

  test('断档（超过 10 分钟）另起一段，不连成一条直线', () {
    final segs = Gpx.segmentsOf([pt(0), pt(1), pt(30), pt(31)]);
    expect(segs.length, 2);
    expect(segs[0].length, 2);
    expect(segs[1].length, 2);
    // 时间倒着走的相邻点也要断开（改过系统时间 / 换定位源）
    expect(Gpx.segmentsOf([pt(5), pt(1)]).length, 2);
    // 空列表不炸
    expect(Gpx.segmentsOf(const <TrackLogPoint>[]), isEmpty);
  });

  test('日期里的 XML 特殊字符被转义（文件是给别人解析的）', () {
    final xml = Gpx.encode([DayTrack('2026-10-16<&>', [pt(0)])]);
    expect(xml.contains('<name>2026-10-16&lt;&amp;&gt;</name>'), isTrue);
    expect(xml.contains('<&>'), isFalse);
  });

  test('空的一天被跳过，metadata 的 name 用首末日期', () {
    final xml = Gpx.encode([
      DayTrack('2026-10-14', const []),
      DayTrack('2026-10-15', [pt(0)]),
      DayTrack('2026-10-16', [pt(0)]),
    ]);
    expect('<trk>'.allMatches(xml).length, 2);
    expect(xml.contains('<name>APRSLocus 2026-10-15 to 2026-10-16</name>'),
        isTrue);
  });
}
