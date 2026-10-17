/// 地图图层筛选「能记忆」的回归测试。
///
/// 用户要求：「地图筛选也会重置」→ 图层面板里关掉的台站类型（以及「套用台站面板
/// 筛选」这颗开关）重启后要保持。它们原来都活在地图页的 State / 一个不落盘的字段里。
///
/// 为什么钉在 CI：这类错**编译能过、analyze 也全绿**，只表现成「怎么又全显示出来了」。
/// 另外两条同样哑的错也一并钉住：
///   * 偏好里存的是类型**名字**，认不出的名字（改名 / 改坏）必须被丢掉，
///     不能把它当成某个类型悄悄隐藏掉；
///   * 清掉筛选之后也该落盘 —— 否则重启后旧筛选又回来。
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

  test('默认不隐藏任何类型，也不套用台站面板筛选', () async {
    final st = await fresh();
    expect(st.mapHiddenTypes, isEmpty);
    expect(st.applyFilterToMap, isFalse);
  });

  test('关掉两个类型后落盘：新实例能读回来（按名字、不分顺序）', () async {
    final a = await fresh();
    a.toggleMapHiddenType(TypeGroup.wx);
    a.toggleMapHiddenType(TypeGroup.fmo);
    await a.persistNow();

    final b = await fresh();
    expect(b.mapHiddenTypes, {TypeGroup.wx, TypeGroup.fmo});
  });

  test('再点一下同一个类型就是打开它', () async {
    final a = await fresh();
    a.toggleMapHiddenType(TypeGroup.mobile);
    expect(a.mapHiddenTypes.contains(TypeGroup.mobile), isTrue);
    a.toggleMapHiddenType(TypeGroup.mobile);
    expect(a.mapHiddenTypes.contains(TypeGroup.mobile), isFalse);
  });

  test('清空筛选也落盘', () async {
    final a = await fresh();
    a.toggleMapHiddenType(TypeGroup.infra);
    await a.persistNow();
    a.clearMapHiddenTypes();
    await a.persistNow();

    final b = await fresh();
    expect(b.mapHiddenTypes, isEmpty, reason: '清掉的筛选不该在重启后回来');
  });

  test('「套用台站面板筛选」也落盘', () async {
    final a = await fresh();
    a.setApplyFilterToMap(true);
    await a.persistNow();

    final b = await fresh();
    expect(b.applyFilterToMap, isTrue);
  });

  test('偏好里的类型名认不出时丢掉，不影响其它项', () async {
    SharedPreferences.setMockInitialValues({
      'mapHiddenTypes': ['wx', 'bogus', 'fmo'],
    });
    final st = await fresh();
    expect(st.mapHiddenTypes, {TypeGroup.wx, TypeGroup.fmo});
  });
}
