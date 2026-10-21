// SPDX-License-Identifier: GPL-2.0-or-later
/// ─── 灵动岛 / 锁屏实时活动（Live Activity）───
///
/// iOS 侧的「实时更新」：与 Android 16 的状态栏胶囊是同一件事 —— 把常驻状态
/// 压成一行，挂在锁屏和灵动岛上。原生实现在 `ios/Runner/LiveActivityPlugin.swift`，
/// 外观在 `ios/LiveActivityWidget/`。
///
/// 三条规矩：
///   1. 只有 iOS 会走这条路，其它平台这些方法直接返回（不抛异常）；
///   2. 内容没变就不发 —— 这个方法跟着定位回调每秒都在被调用，逐字重发会让
///      系统把它当成刷屏；
///   3. 没有活动时不 `end` —— 本来就没有，再发一次结束只是白跑一趟通道。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class LiveActivity {
  LiveActivity._();

  static const MethodChannel _channel =
      MethodChannel('com.aprslocus/live_activity');

  /// 问过原生没有（只问一次：系统开关不会在运行中变来变去）。
  static bool _asked = false;
  static bool _available = false;

  /// 当前是否有活动挂着。
  static bool _running = false;

  /// 上一次送出去的内容，用来去重。
  static String _lastKey = '';

  /// 这条平台有没有这个能力（只有 iOS 有）。
  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// 用户在系统设置里关掉实时活动、或系统版本不够时返回 false。
  static Future<bool> available() async {
    if (!_supported) return false;
    if (_asked) return _available;
    _asked = true;
    try {
      _available = await _channel.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      _available = false;
    }
    return _available;
  }

  /// 更新（没有就开一条）。[endsAt] 非空时锁屏与灵动岛画系统倒计时。
  static Future<void> update({
    required String call,
    required String line,
    String short = '',
    DateTime? endsAt,
  }) async {
    if (!_supported) return;
    if (!await available()) return;
    // 倒计时按整秒对齐：每秒重开一次活动只改一个字，既费电也会被系统限流。
    final endsMs = endsAt == null
        ? 0
        : (endsAt.millisecondsSinceEpoch ~/ 1000) * 1000;
    final key = '$call|$line|$short|$endsMs';
    if (_running && key == _lastKey) return;
    _lastKey = key;
    _running = true;
    try {
      await _channel.invokeMethod('update', {
        'call': call,
        'line': line,
        'short': short,
        'endsAtMs': endsMs,
      });
    } catch (_) {
      // 原生没接上（旧包 / 系统拒绝）：下次照常重试，不往外抛。
      _running = false;
    }
  }

  /// 收掉这条活动（关掉实时更新、断开连接、退出应用时调）。
  static Future<void> end() async {
    if (!_supported || !_running) return;
    _running = false;
    _lastKey = '';
    try {
      await _channel.invokeMethod('end');
    } catch (_) {}
  }
}
