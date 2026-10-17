/// 台站筛选「能记忆」的回归测试。
///
/// 用户要求：「记住台站筛选」。它原来只活在台站面板的 State 里
/// （`StationFilter stationFilter` 存在 AppState，但从不落盘），关掉应用就回到
/// 「全部」—— 下次打开要在几个 chips 之间重新点一遍。
///
/// 为什么钉在 CI：这类错**编译能过、analyze 也全绿**，只表现成「怎么又变回全部
/// 台站了」。另外三条同样哑的错也一并钉住：
///   * 脏值（改坏偏好文件 / 旧版写进去的档位）不该让面板变成第三种状态，
///     也不该继续被写回去；
///   * 设备 / 型号这两个自由字段也要读回来（它们不是固定档位，最容易漏写）；
///   * 没变化时不该反复写盘。
library;

import 'package:aprslocus/models.dart';
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

  test('默认为空筛选', () async {
    final st = await fresh();
    expect(st.stationFilter.isEmpty, isTrue);
  });

  test('选过的筛选落盘：新实例能读回来', () async {
    final a = await fresh();
    a.setStationFilter(const StationFilter(
      status: 'moving',
      type: 'mobile',
      app: 'aprslocus',
      dev: 'aprs',
      model: 'FTM-400',
      favoriteOnly: true,
    ));
    await a.persistNow(); // 保证写入完成（不只是 fire-and-forget）

    final b = await fresh();
    final f = b.stationFilter;
    expect(f.status, 'moving');
    expect(f.type, 'mobile');
    expect(f.app, 'aprslocus');
    expect(f.dev, 'aprs');
    expect(f.model, 'FTM-400');
    expect(f.favoriteOnly, isTrue);
  });

  test('偏好文件里是脏值时回到空筛选（不变成第三种状态）', () async {
    SharedPreferences.setMockInitialValues({
      'stationFilterJson':
          '{"status":"bogus","type":42,"app":null,"dev":[],"model":"X",'
              '"favoriteOnly":"yes"}',
    });
    final st = await fresh();
    final f = st.stationFilter;
    expect(f.status, 'all');
    expect(f.type, 'all');
    expect(f.app, 'all');
    expect(f.dev, 'all', reason: '非字符串一律回落');
    expect(f.model, 'X', reason: '合法的自由字段照常读回');
    expect(f.favoriteOnly, isFalse);
  });

  test('偏好文件不是 JSON 也不崩', () async {
    SharedPreferences.setMockInitialValues({'stationFilterJson': 'not json'});
    final st = await fresh();
    expect(st.stationFilter.isEmpty, isTrue);
  });

  test('筛选没变化时不写盘（别把脏偏好反写成别的值）', () async {
    final a = await fresh();
    a.setStationFilter(const StationFilter(status: 'online'));
    a.setStationFilter(const StationFilter(status: 'online'));
    expect(a.stationFilter.status, 'online');
  });

  test('清空筛选也落盘', () async {
    final a = await fresh();
    a.setStationFilter(const StationFilter(type: 'wx'));
    await a.persistNow();
    a.setStationFilter(const StationFilter());
    await a.persistNow();

    final b = await fresh();
    expect(b.stationFilter.isEmpty, isTrue, reason: '清掉的筛选不该在重启后回来');
  });
}
