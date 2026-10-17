// SPDX-License-Identifier: GPL-2.0-or-later
// See LICENSING.md: this file is additionally available under GPL-2.0-or-later.
//
// 外置 GPS 供位时，手机定位的「待机 / 接回」。
//
// 用户报的「断开外置 GPS 后自动上报停了、手动上报只有报文没有位置」：那时
// `AppState._syncPhoneGps` 在模块接管时调的是 `loc.stop()` —— 它除了关掉定位采样，
// 还会拆掉前台服务、WakeLock 与定位事件订阅。应用一退到后台就被系统冻结：
// APRS-IS 连接静默死掉、信标定时器停摆，而界面上的「已连接」还亮着；手机侧采样
// 也没有人再接回来（tick 跟着一起冻住）。
//
// 现在改成「只切原生定位模式」（`pauseForExternal` → `setLocationMode: keepalive`，
// 见 `LocationService.setModeStatic`：注销 provider 监听，前台服务与 WakeLock 原样保留），
// 接回则是把原来的模式切回去，不用重启服务。
//
// 这几条断言编译能过、analyze 也全绿，错了只会表现成「后台悄悄不发」，只能靠 CI 钉住
// （手工登记在 .github/workflows/ci-test.yml）。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aprslocus/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.aprslocus/location');

  /// 原生收到的调用（`方法:模式`，无参数时只有方法名）
  late List<String> calls;
  late LocService loc;

  setUp(() {
    calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      // start() 会先问权限；主机上没有原生侧，直接放行
      if (call.method == 'checkPermissions') return true;
      final args = call.arguments;
      calls.add(args is Map && args['mode'] != null
          ? '${call.method}:${args['mode']}'
          : call.method);
      return null;
    });
    loc = LocService();
  });

  tearDown(() {
    // setMockMethodCallHandler 返回 void（不能 await）—— 与本仓库其它测试一致
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('待机只切定位模式，绝不停前台服务', () async {
    loc.debugMarkRunning();
    expect(await loc.pauseForExternal(), isTrue);
    expect(calls, <String>['setLocationMode:keepalive']);
    // 关键回归：服务还在（后台生存、常驻通知、APRS-IS 连接都靠它）
    expect(calls.contains('stopService'), isFalse);
    expect(loc.running, isTrue);
    expect(loc.pausedForExternal, isTrue);
  });

  test('接回时切回原来的定位模式，而不是重启服务', () async {
    loc.mode = 'network';
    loc.debugMarkRunning();
    await loc.pauseForExternal();
    expect(await loc.resumeFromExternal(), isTrue);
    expect(calls, <String>[
      'setLocationMode:keepalive',
      'setLocationMode:network',
    ]);
    expect(loc.pausedForExternal, isFalse);
    expect(loc.running, isTrue);
  });

  test('没在跑的时候不假装停过（返回值让调用方改走 startTracking）', () async {
    expect(await loc.pauseForExternal(), isFalse);
    expect(calls, isEmpty);
    expect(loc.pausedForExternal, isFalse);
  });

  test('服务被停掉之后不再拿旧状态去恢复', () async {
    loc.debugMarkRunning();
    await loc.pauseForExternal();
    loc.stop();
    expect(loc.pausedForExternal, isFalse);
    expect(await loc.resumeFromExternal(), isFalse);
  });

  test('平台通道抛异常不会把待机标记留成脏值', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'boom');
    });
    loc.debugMarkRunning();
    expect(await loc.pauseForExternal(), isFalse);
    // 没切成 keepalive 就不能说已待机，否则外置失效时不会有人去接回手机定位
    expect(loc.pausedForExternal, isFalse);
  });
}
