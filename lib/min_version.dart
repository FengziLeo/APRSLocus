import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'version_compare.dart';

/// ─── 官网下发的最低版本 ───
///
/// 从官网读一份 JSON（`assets/min_version.json`）。本机版本**低于**它时，
/// 应用只显示更新页这一条路（见 `lib/min_version_page.dart`），点别处没有出口。
/// 用途只有一句话：某个旧版本有必须下线的缺陷时，能把它从用户手里收回来。
///
/// ── 三条设计原则（与远程限制名单同一套，理由也同一套）──
///
///  1. **失败放行**：从没成功拉到过（离线 / 接口挂了 / JSON 坏了）**不拦人**。
///     一次网络抖动不能把所有用户挡在门外。
///  2. **拉到过就认缓存**：成功拉到过，之后离线也按上次那份判断。
///     否则改一下 Hosts 就能绕过。更新到新版本后版本号自己就超过下限，闸门随之消失。
///  3. **下限留空 = 不设下限**：官网那份文件的 `minVersion` 为空串时谁都不拦。
///     发版后想拦旧版，填上版本号即可，不必等应用更新。
///
/// ── 文件格式（官网 `docs/assets/min_version.json`）──
/// ```json
/// { "updated": "2026-10-20",
///   "minVersion": "2.1.20",
///   "reason": "2.1.20 之前的版本…" }
/// ```
/// `reason` 会原样显示在拦截页上（可空）。写错的版本号（比如 `abc`）比较时
/// 判不出来，按"不拦"处理 —— 手写的文件，宁可漏拦也别把人锁在外面。
class MinVersion {
  /// 官网基址（与用户协议、公告、限制名单同一个站点）
  static const String kBase = 'https://aprslocus.theez.top/';
  static const String kPath = 'assets/min_version.json';

  static const String _kCache = 'minVersionCacheJson';
  static const String _kCheckedAt = 'minVersionCheckedAt';

  /// 拉到新的一份后多久再拉一次
  static const Duration kRefresh = Duration(hours: 6);

  /// 最低可用版本（已去掉前导 `v`）。**空串 = 不设下限**。
  final String minVersion;

  /// 给用户看的一句话（为什么必须更新）。可空。
  final String reason;

  /// 这份文件的更新日期。可空。
  final String updated;

  const MinVersion({this.minVersion = '', this.reason = '', this.updated = ''});

  /// 是否设了下限。
  bool get active => minVersion.isNotEmpty;

  /// 本机版本 [current] 是否低于下限。
  ///
  /// 没设下限 / 版本号写错（比较判不出来）都返回 false —— 见类注释第 3 条。
  bool blocks(String current) =>
      active && compareVersions(current, minVersion) < 0;

  static String _norm(Object? v) =>
      (v?.toString() ?? '').trim().replaceFirst(RegExp('^[Vv]'), '');

  /// 解析文件。**坏 JSON / 结构不对返回 null**（调用方按"没查到"处理）。
  static MinVersion? parse(String text) {
    try {
      final j = jsonDecode(text);
      if (j is! Map) return null;
      // 只有 map 结构算"读到了"。minVersion 缺失或为空都算"不设下限"。
      return MinVersion(
        minVersion: _norm(j['minVersion'] ?? j['min_version']),
        reason: (j['reason'] ?? '').toString().trim(),
        updated: (j['updated'] ?? '').toString().trim(),
      );
    } catch (_) {
      return null;
    }
  }

  /// 读本地缓存（没有 / 坏了 → null）
  static Future<MinVersion?> cached() async {
    try {
      final p = await SharedPreferences.getInstance();
      final s = p.getString(_kCache);
      if (s == null || s.isEmpty) return null;
      return parse(s);
    } catch (_) {
      return null;
    }
  }

  /// 上次成功拉取的时间（给节流用）
  static Future<DateTime?> lastChecked() async {
    try {
      final p = await SharedPreferences.getInstance();
      final ms = p.getInt(_kCheckedAt);
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }

  /// 拉一份新的并写缓存。**失败返回 null**（调用方据此沿用缓存 / 放行）。
  static Future<MinVersion?> fetch(
      {Duration timeout = const Duration(seconds: 8)}) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = timeout;
      final url = Uri.parse(kBase).resolve(kPath).toString();
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'APRSlocus');
      final res = await req.close();
      if (res.statusCode != 200) return null;
      final text = await res.transform(utf8.decoder).join().timeout(timeout);
      final mv = parse(text);
      if (mv == null) return null;
      final p = await SharedPreferences.getInstance();
      await p.setString(_kCache, text);
      await p.setInt(_kCheckedAt, DateTime.now().millisecondsSinceEpoch);
      return mv;
    } catch (_) {
      return null; // 失败放行（见类注释第 1 条）
    } finally {
      client?.close(force: true);
    }
  }
}
