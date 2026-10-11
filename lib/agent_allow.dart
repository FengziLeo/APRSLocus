import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// ─── 远程「智能体授权名单」（白名单）───
///
/// 智能体**不对普通用户开放**：默认关闭，且即使打开开关也要先「获授权」。
/// 授权名单从官网读一份 JSON（`assets/agent_allow.json`），名单里**没有**本机
/// 呼号就不放行 —— 架构与远程限制名单（[Blacklist]，`blacklist.dart`）对称，
/// 只是方向相反：那边"命中就拦"，这边"命中才放"。
///
/// ── 与黑名单**关键的不同：默认拒绝** ──
///
/// 黑名单是"失败放行"（拉不到就不拦人）；白名单是"失败不放行" —— 它就是门上
/// 那把锁，锁没拿到钥匙（名单）时当然不能开。但**离线不等于没授权**：只要**曾经**
/// 成功拉到过名单（有缓存），离线时按缓存判 —— 授权过的人断网也能用。
///
/// ── 这只是"客户端礼貌锁" ──
///
/// 本软件是 GPL-3.0 开源，任何人都能自己编译一份去掉这段检查的版本。它挡的是
/// "用官方安装包的人"，不是有心人。真正的约束在申请/审核流程与呼吁守约上。
///
/// ── 名单文件格式（官网 `docs/assets/agent_allow.json`）──
/// ```json
/// { "updated": "2026-10-03",
///   "entries": [ { "call": "BG7LZQ", "note": "软件作者", "at": "2026-10-03" },
///                { "call": "BH7*",   "note": "…" } ] }   // 支持 `*` 通配符
/// ```
/// `call` 的匹配规则见 [AgentAllowEntry.hitsCall]：与黑名单一致 —— 写裸呼号
/// = 授权这个人的所有 SSID；写 `CALL-N` = 只授权那一台；`*` 为任意串。
class AgentAllowEntry {
  final String call;   // 呼号模式（大写；可含 `*`）
  final String note;   // 备注（给用户看的说明，可空）
  final String at;     // 授权日期（可空）

  const AgentAllowEntry({required this.call, this.note = '', this.at = ''});

  /// 这条到底能不能用来授权。
  ///
  /// 呼号里**至少要有一个非通配符字符**：只写 `*`（或 `-*`）等于"授权所有人"，
  /// 一律作废 —— 名单是手写的，手滑一个星号不能把智能体对所有人开放。
  bool get usable => call.replaceAll('*', '').replaceAll('-', '').isNotEmpty;

  /// 该呼号是否命中本条目（大小写不敏感）。规则与黑名单一致：
  ///
  ///   1. `CALL`（不带 SSID、也不带 `*`）→ 授权这个呼号及其**任意 SSID**（0–15）；
  ///   2. `CALL-N`（带 SSID）→ 只授权**那一台**；
  ///   3. `CALL-*` → 与规则 1 等价；
  ///   4. 其他位置的 `*` → 任意串（`BH7*`、`*LZQ-9`）。
  bool hitsCall(String call) {
    final c = call.trim().toUpperCase();
    final p = this.call;
    if (p.isEmpty || c.isEmpty) return false;
    if (!p.contains('-') && !p.contains('*')) return _withSsids(p, c);
    if (!p.contains('*')) return p == c;
    final head = p.endsWith('-*') ? p.substring(0, p.length - 2) : null;
    if (head != null && head.isNotEmpty && !head.contains('*')) {
      return _withSsids(head, c);
    }
    return RegExp('^${p.split('*').map(RegExp.escape).join('.*')}\$').hasMatch(c);
  }

  static bool _withSsids(String base, String call) =>
      call == base ||
      RegExp('^${RegExp.escape(base)}-[0-9]{1,2}\$').hasMatch(call);

  static AgentAllowEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final call = j['call']?.toString().trim().toUpperCase() ?? '';
    if (call.isEmpty) return null;
    return AgentAllowEntry(
      call: call,
      note: j['note']?.toString() ?? '',
      at: j['at']?.toString() ?? '',
    );
  }
}

class AgentAllow {
  /// 官网基址（与用户协议、公告、限制名单同一个站点）
  static const String kBase = 'https://aprslocus.theez.top/';
  static const String kPath = 'assets/agent_allow.json';

  /// 申请授权的邮箱（承诺书寄到这里）
  static const String kApplyEmail = 'mc081208@163.com';

  /// 承诺书（官网静态文本，点「下载承诺书」时用系统浏览器打开）
  static const String kCommitmentZh = 'assets/agent_commitment_zh.txt';
  static const String kCommitmentEn = 'assets/agent_commitment_en.txt';

  static const String _kCache = 'agentAllowCacheJson';
  static const String _kCheckedAt = 'agentAllowCheckedAt';

  /// 拉到新名单后多久再拉一次（与黑名单同一个节流窗口）
  static const Duration kRefresh = Duration(hours: 6);

  final List<AgentAllowEntry> entries;
  final String updated;

  const AgentAllow(this.entries, {this.updated = ''});

  /// 解析名单。**坏 JSON / 结构不对一律返回 null**（调用方按"未知"处理）。
  static AgentAllow? parse(String text) {
    try {
      final j = jsonDecode(text);
      if (j is! Map) return null;
      final raw = j['entries'];
      if (raw is! List) return null;
      final out = <AgentAllowEntry>[];
      for (final it in raw) {
        final e = AgentAllowEntry.fromJson(it);
        if (e != null && e.usable) out.add(e);
      }
      return AgentAllow(out, updated: j['updated']?.toString() ?? '');
    } catch (_) {
      return null;
    }
  }

  /// 名单里是否有这个呼号（大小写不敏感，SSID 规则见 [AgentAllowEntry.hitsCall]）。
  bool allows(String call) {
    final c = call.trim();
    if (c.isEmpty) return false;
    for (final e in entries) {
      if (e.hitsCall(c)) return true;
    }
    return false;
  }

  /// 读本地缓存的名单（没有 / 坏了 → null）
  static Future<AgentAllow?> cached() async {
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

  /// 拉一份新名单并写缓存。**失败返回 null**（调用方据此沿用缓存 / 判为未知）。
  static Future<AgentAllow?> fetch(
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
      final al = parse(text);
      if (al == null) return null;
      final p = await SharedPreferences.getInstance();
      await p.setString(_kCache, text);
      await p.setInt(_kCheckedAt, DateTime.now().millisecondsSinceEpoch);
      return al;
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }
}
