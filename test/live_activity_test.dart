// 灵动岛（Live Activity）的 Dart 侧回归。
//
// 这段逻辑只有真机 iPhone 上才看得见，而它最容易错的两点都不报编译错误：
//   ① 去重写坏 —— 定位回调每秒都调一次，逐字重发会让系统当成刷屏限流；
//   ② 非 iOS 平台没拦住 —— Android 上会白跑一次通道，抛 MissingPlugin 之
//      后又被 catch 掉，看起来「没事」，其实是每次都失败。
// 所以用 mock 通道钉住「调了几次、参数是什么」。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aprslocus/live_activity.dart';

const _channel = MethodChannel('com.aprslocus/live_activity');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    calls.add(call);
    if (call.method == 'available') return true;
    return null;
  });

  tearDown(calls.clear);

  test('Android 上完全不碰通道', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await LiveActivity.update(call: 'BG7LZQ-7', line: '正在上报', short: '12s');
    await LiveActivity.end();
    expect(calls, isEmpty);
    debugDefaultTargetPlatformOverride = null;
  });

  test('iOS：内容没变不重复发，变了才发，结束后不再发', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final first = DateTime.fromMillisecondsSinceEpoch(1700000000123);
    final sameSecond = DateTime.fromMillisecondsSinceEpoch(1700000000980);

    await LiveActivity.update(
        call: 'BG7LZQ-7', line: '已连接 · 距下次上报 20s', short: '20s', endsAt: first);
    expect(calls.where((c) => c.method == 'update').length, 1);
    final args = calls.last.arguments as Map;
    expect(args['call'], 'BG7LZQ-7');
    expect(args['short'], '20s');
    // 倒计时按整秒对齐：同一秒里的不同毫秒不该算「变了」。
    expect(args['endsAtMs'], 1700000000000);

    await LiveActivity.update(
        call: 'BG7LZQ-7',
        line: '已连接 · 距下次上报 20s',
        short: '20s',
        endsAt: sameSecond);
    expect(calls.where((c) => c.method == 'update').length, 1,
        reason: '同一秒内的倒计时抖动不该重发');

    await LiveActivity.update(
        call: 'BG7LZQ-7', line: '已连接 · 距下次上报 19s', short: '19s', endsAt: first);
    expect(calls.where((c) => c.method == 'update').length, 2);

    await LiveActivity.end();
    expect(calls.where((c) => c.method == 'end').length, 1);
    await LiveActivity.end();
    expect(calls.where((c) => c.method == 'end').length, 1,
        reason: '没有活动时再 end 是白跑通道');
    debugDefaultTargetPlatformOverride = null;
  });
}
