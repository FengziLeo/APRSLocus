/// 台站列表排序「能记忆」的回归测试。
///
/// 用户要求：台站面板右上角那颗排序入口（呼号 / 最近 / 距离 / 状态）选过之后
/// 要记住。它原来只活在页面的 State 里（`String _sort = 'call'`），退出面板就
/// 回到默认 —— 所以改成存 [AppState.stationSort] 并落盘。
///
/// 为什么钉在 CI：这类错**编译能过、analyze 也全绿**，只表现成「怎么又变回
/// 按呼号排了」。另外两条同样哑的错也一并钉住：
///   * 脏值（改坏偏好文件 / 旧版本写进去的东西）不该让排序变成第三种行为，
///     更不该继续被写回去；
///   * 落盘之后必须真的能读回来（换机 / 冷启动）。
library;

import 'package:aprslocus/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// 构造函数里的 [_loadPrefs] 是异步的：不等它落地，会被它覆盖。
  Future<AppState> fresh() async {
    final st = AppState();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return st;
  }

  test('默认按呼号排', () async {
    final st = await fresh();
    expect(st.stationSort, 'call');
  });

  test('选过之后落盘：新实例能读回来', () async {
    final a = await fresh();
    a.setStationSort('distance');
    expect(a.stationSort, 'distance');
    await a.persistNow(); // 保证写入完成（不只是 fire-and-forget）

    final b = await fresh();
    expect(b.stationSort, 'distance', reason: '冷启动后排序该记得');
  });

  test('非法值既不生效也不写回（脏偏好只回落一次）', () async {
    final a = await fresh();
    a.setStationSort('recent');
    a.setStationSort('bogus');
    expect(a.stationSort, 'recent', reason: '认不出的值直接忽略');
    await a.persistNow();

    final b = await fresh();
    expect(b.stationSort, 'recent', reason: '脏值不该被写进偏好');
  });

  test('偏好文件里是脏值时回到默认的按呼号排', () async {
    SharedPreferences.setMockInitialValues({'stationSort': 'whatever'});
    final st = await fresh();
    expect(st.stationSort, 'call');
  });

  test('菜单给出的四个选项都认', () async {
    final st = await fresh();
    for (final v in AppState.stationSorts) {
      st.setStationSort(v);
      expect(st.stationSort, v);
    }
    expect(AppState.stationSorts.first, 'call',
        reason: '默认值必须在选项里，否则一开面板就显示成 fallback');
  });
}
