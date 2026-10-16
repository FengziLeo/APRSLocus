/// ─── 历史轨迹 → GPX ───
///
/// 只做一件事：把 [DayTrack] 台账写成 GPX 1.1 文本。**不碰 IO** —— 写盘交给
/// 调用方（与 `adif.dart` 的分工一致），这样这段逻辑能在测试里逐字比对。
///
/// 几条刻意的取舍：
///
///   * **一天一条 `<trk>`**：GPX 的 `<trk>` 是「一次记录」。按天切开导进
///     Strava / Garmin Connect / Google Earth 之后，看到的是一天一条行程，
///     而不是一个月糊成一条线。
///   * **断档切 `<trkseg>`**：应用被系统杀掉、进隧道丢信号时，相邻两点可能隔
///     几小时。留在同一段里会被画成一条跨几百公里的直线 —— 那是**编造出来的
///     轨迹**，比断开更坏。间隔超过 [segGap] 就另起一段。
///   * **海拔 / 心率只写有的**：没有读数时整个元素不写。补一个 0 会得到一条
///     贴着海平面的海拔线、一条塌到 0 的心率线，读者以为真发生过。
///   * **速度与航向不写**：它们在 GPX 1.1 里已经从 `<trkpt>` 移出（1.0 时代的
///     `<speed>` / `<course>` 不再是标准字段）。要么自造命名空间、要么落到
///     各家扩展里 —— 那属于「猜导入方认什么」。宁可少写两个字段，也不写一份
///     别人可能读错的扩展。
class Gpx {
  Gpx._();

  /// 相邻两点间隔超过这么久就断成新的 `<trkseg>`。
  ///
  /// 10 分钟这个数取自「一次断档」的量级：正常记录是秒级一个点，停下来吃饭
  /// 也是连续的点，只有被杀进程 / 没信号才会出现分钟级的空档。
  static const Duration segGap = Duration(minutes: 10);

  /// 导出文件名：单天 `APRSLocus-2026-10-16.gpx`，跨天用 `_` 连起来。
  ///
  /// 用连字符与下划线、不用空格：安卓的下载目录与各家云盘对空格的处理不一致，
  /// 有的会替换成 `%20`，用户拿到的名字和界面上写的不一样。
  static String fileName(String fromDay, String toDay) => fromDay == toDay
      ? 'APRSLocus-$fromDay.gpx'
      : 'APRSLocus-${fromDay}_$toDay.gpx';

  /// 把若干天的轨迹拼成一份 GPX 文档。
  ///
  /// [days] 不必有序（`loadAll()` 给的是倒序，调用方传进来什么就按什么顺序写，
  /// 但内部按 `day` 升序排一次 —— 文件里日期从早到晚更好读）。
  /// [now] 只用于 `<metadata><time>`，测试里固定住它才有可比的输出。
  static String encode(List<DayTrack> days, {DateTime? now}) {
    final sorted = List<DayTrack>.from(days)
      ..sort((a, b) => a.day.compareTo(b.day));
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
        '<gpx version="1.1" creator="APRSLocus"'
        ' xmlns="http://www.topografix.com/GPX/1/1"'
        ' xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1"'
        ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
        ' xsi:schemaLocation="http://www.topografix.com/GPX/1/1'
        ' http://www.topografix.com/GPX/1/1/gpx.xsd">',
      );

    final from = sorted.isEmpty ? null : sorted.first.day;
    final to = sorted.isEmpty ? null : sorted.last.day;
    b
      ..writeln('  <metadata>')
      ..writeln('    <name>${_esc(_metaName(from, to))}</name>')
      ..writeln('    <time>${_isoUtc(now ?? DateTime.now())}</time>')
      ..writeln('  </metadata>');

    for (final d in sorted) {
      if (d.points.isEmpty) continue;
      b
        ..writeln('  <trk>')
        ..writeln('    <name>${_esc(d.day)}</name>');
      for (final seg in segmentsOf(d.points)) {
        b.writeln('    <trkseg>');
        for (final p in seg) {
          b
            ..writeln('      <trkpt lat="${p.lat.toStringAsFixed(6)}"'
                ' lon="${p.lng.toStringAsFixed(6)}">');
          if (p.alt != null) b.writeln('        <ele>${_m1(p.alt!)}</ele>');
          b.writeln('        <time>${_isoUtc(p.time)}</time>');
          if (p.hr != null && p.hr! > 0) {
            b
              ..writeln('        <extensions>')
              ..writeln('          <gpxtpx:TrackPointExtension>')
              ..writeln('            <gpxtpx:hr>${p.hr}</gpxtpx:hr>')
              ..writeln('          </gpxtpx:TrackPointExtension>')
              ..writeln('        </extensions>');
          }
          b.writeln('      </trkpt>');
        }
        b.writeln('    </trkseg>');
      }
      b.writeln('  </trk>');
    }

    b.writeln('</gpx>');
    return b.toString();
  }

  /// 按 [segGap] 把点列切成若干段（输入已按时间升序，见 [DayTrack.fromJson]）。
  ///
  /// 时间**倒着**的相邻点也断开：那是设备改过系统时间或定位源切换的产物，
  /// 画出来会在同一段里来回折返。
  static List<List<TrackLogPoint>> segmentsOf(List<TrackLogPoint> pts) {
    final out = <List<TrackLogPoint>>[];
    if (pts.isEmpty) return out;
    var cur = <TrackLogPoint>[pts.first];
    for (var i = 1; i < pts.length; i++) {
      final gap = pts[i].time.difference(pts[i - 1].time);
      if (gap.isNegative || gap > segGap) {
        out.add(cur);
        cur = <TrackLogPoint>[pts[i]];
      } else {
        cur.add(pts[i]);
      }
    }
    out.add(cur);
    return out;
  }

  static String _metaName(String? from, String? to) {
    if (from == null || to == null) return 'APRSLocus';
    if (from == to) return 'APRSLocus $from';
    return 'APRSLocus $from to $to';
  }

  /// `2026-10-16T08:12:33Z` —— GPX 要求 UTC 的 ISO 8601。
  ///
  /// 不用 `toIso8601String()`：那会带上 `.000` 毫秒与（本地时间的）无 Z 结尾，
  /// 前者有人不认、后者是错的时区。
  static String _isoUtc(DateTime t) {
    final u = t.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
        'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
  }

  /// 米，一位小数（0.1 m 已经远小于 GPS 精度，再多写就是假精度）
  static String _m1(double v) => v.toStringAsFixed(1);

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}
