// SPDX-License-Identifier: GPL-2.0-or-later
// See LICENSING.md: this file is additionally available under GPL-2.0-or-later.
//
// 常驻前台服务通知的**去重**。
//
// 用户报的「有概率反复弹出待确认上报」：通知文字由 AppState 整体重拼（`_updateNotification()`
// 在每次定位回调、台站/统计变化、15 秒保活 tick、链路翻转上都会调），而原生侧
// `LocationService.kt` 的 `updateNotification()` 是 `nm.notify(ID, buildNotification(text))`
// —— **文字没变也照发**。同一条文字被反复 notify()，很多 ROM 会把它当成「又来一条」再弹
// 一次，用户看到的就是通知栏反复弹出「信标 待确认上报」。
//
// 所以去重放在 `LocService.updateNotification()` 这个唯一的出口上。这几条断言**编译能过、
// analyze 也全绿**，错了只会表现成「偶发多弹一次」或「通知文字再也不更新」，只能靠 CI 钉住
// （手工登记在 .github/workflows/ci-test.yml）。
//
// 原生侧的另一半是 `LocationService.kt` 的 `.setOnlyAlertOnce(true)`；Dart 这边测不到，
// 改那里时不用改这个文件，但别把它删了。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aprslocus/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.aprslocus/location');

  late List<String> sent;
  late LocService loc;

  setUp(() {
    sent = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'updateNotification') {
        sent.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    loc = LocService();
  });

  tearDown(() async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('同一条文字只发一次（这是「反复弹出」的根因）', () async {
    await loc.updateNotification('信标 待确认上报');
    await loc.updateNotification('信标 待确认上报');
    await loc.updateNotification('信标 待确认上报');
    expect(sent, <String>['信标 待确认上报']);
  });

  test('第一次永远发得出去（不能因为空串初值被吃掉）', () async {
    await loc.updateNotification('');
    expect(sent, <String>['']);
    await loc.updateNotification('');
    expect(sent, <String>['']);
  });

  test('文字变了就发；变回去也发（倒计时/台站数跳动时要真实刷新）', () async {
    await loc.updateNotification('信标 待确认上报 · GPS·PM01');
    await loc.updateNotification('信标 待确认上报 · GPS·PM01 · 台站 12');
    await loc.updateNotification('信标 待确认上报 · GPS·PM01');
    expect(sent, <String>[
      '信标 待确认上报 · GPS·PM01',
      '信标 待确认上报 · GPS·PM01 · 台站 12',
      '信标 待确认上报 · GPS·PM01',
    ]);
  });

  test('服务停过之后，同一条文字必须重发', () async {
    // 服务重启时原生手上只有 onStartCommand 写下的占位文字，
    // 去重如果只看文字，通知就会永远停在占位状态。
    await loc.updateNotification('信标 待确认上报');
    loc.stop();
    await loc.updateNotification('信标 待确认上报');
    expect(sent.length, 2);
    // 重发之后回到正常去重
    await loc.updateNotification('信标 待确认上报');
    expect(sent.length, 2);
  });

  test('平台通道抛异常不会炸掉刷新（通知失败不影响定位）', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'boom');
    });
    await loc.updateNotification('信标 待确认上报');
  });
}
