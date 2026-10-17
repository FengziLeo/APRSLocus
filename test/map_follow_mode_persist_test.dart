/// 地图「锁定地图中心」三态「能记忆」的回归测试。
///
/// 用户要求：「地图航向锁定选择每次启动后都会重置，不能保持上次选择」。这一档
/// 原来只活在地图页的 State 字段里（`int _followMode = 0`），冷启动就回到「关」。
///
/// 为什么钉在 CI：这类错**编译能过、analyze 也全绿**，只表现成「怎么又回到不锁了」。
/// 另外两条同样哑的错也一并钉住：
///   * 只有 0/1/2 三档，脏值（改坏偏好 / 旧版写进去的数）必须夹回合法范围，
///     否则 _followMode 会变成一个既非「关」也非「航向朝上」的第三态；
///   * 选 2（航向朝上）之后重启仍要是 2 —— 掉成 1 看起来像「航向跟随坏了」。
library;

import 'package:aprslocus/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// 构造函数里的 `_loadPrefs` 是异步的：不等它落地，会被它覆盖。
  Future<AppState> fresh() async {
    final st = AppState();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return st;
  }

  test('默认不锁（0）', () async {
    final st = await fresh();
    expect(st.mapFollowMode, 0);
  });

  test('选过之后落盘：新实例能读回来', () async {
    final a = await fresh();
    a.setMapFollowMode(2);
    expect(a.mapFollowMode, 2);
    await a.persistNow();

    final b = await fresh();
    expect(b.mapFollowMode, 2, reason: '冷启动后航向朝上那一档该还在');
  });

  test('三档都认', () async {
    final st = await fresh();
    for (final v in [1, 2, 0]) {
      st.setMapFollowMode(v);
      expect(st.mapFollowMode, v);
    }
  });

  test('脏值夹回 0..2，不写进偏好', () async {
    final a = await fresh();
    a.setMapFollowMode(7);
    expect(a.mapFollowMode, 2);
    a.setMapFollowMode(-3);
    expect(a.mapFollowMode, 0);
    await a.persistNow();

    final b = await fresh();
    expect(b.mapFollowMode, 0);
  });

  test('偏好文件里是三档之外的值也夹回默认', () async {
    SharedPreferences.setMockInitialValues({'mapFollowMode': 9});
    final st = await fresh();
    expect(st.mapFollowMode, 2);
  });
}
