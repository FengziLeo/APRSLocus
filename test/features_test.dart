/// 自选模块与精简模式的回归测试。
///
/// 这两件事都**不会让编译或 analyze 失败**，错了只表现成「入口怎么又冒出来了」
/// 或「我调好的模块怎么全丢了」。所以钉在 CI：
///
/// * 偏好里存的是「关掉的模块」，默认全开 —— 将来新增模块才不会因为旧偏好里
///   没有那个 id 而悄悄消失；
/// * 精简模式**不改写**用户的模块选择，关掉它之后原来的选择原样回来；
/// * 偏好里的脏 id（模块删掉、文件被改坏）既不该造出幽灵开关，也不该被写回去。
library;

import 'package:aprslocus/features.dart';
import 'package:aprslocus/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// 构造函数里的 `_loadPrefs` 是异步的：不等它落地会被它覆盖。
  Future<AppState> fresh() async {
    final st = AppState();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return st;
  }

  test('默认全部模块开着，也没在精简模式', () async {
    final st = await fresh();
    expect(st.liteMode, isFalse);
    for (final f in AppFeature.values) {
      expect(st.featureEnabled(f), isTrue, reason: '${f.id} 默认该是开着的');
    }
  });

  test('关掉的模块落盘，新实例读回来', () async {
    final a = await fresh();
    a.setFeature(AppFeature.rank.id, false);
    expect(a.featureEnabled(AppFeature.rank), isFalse);
    expect(a.featureEnabled(AppFeature.honor), isTrue, reason: '只关一个');
    await a.persistNow();

    final b = await fresh();
    expect(b.featureEnabled(AppFeature.rank), isFalse, reason: '冷启动后该记得');
    expect(b.featureEnabled(AppFeature.honor), isTrue);
  });

  test('精简模式按掉全部模块，但不动用户自己的选择', () async {
    final st = await fresh();
    st.setFeature(AppFeature.rank.id, false);
    st.setLiteMode(true);

    expect(st.liteMode, isTrue);
    for (final f in AppFeature.values) {
      expect(st.featureEnabled(f), isFalse, reason: '精简模式下都不显示');
    }
    expect(st.featuresOff, {AppFeature.rank.id}, reason: '只记着用户真关掉的那个');

    st.setLiteMode(false);
    expect(st.featureEnabled(AppFeature.rank), isFalse, reason: '用户自己的选择还在');
    expect(st.featureEnabled(AppFeature.honor), isTrue, reason: '别的模块回来了');
  });

  test('精简模式落盘：新实例还是精简的', () async {
    final a = await fresh();
    a.setFeature(AppFeature.sponsor.id, false);
    a.setLiteMode(true);
    await a.persistNow();

    final b = await fresh();
    expect(b.liteMode, isTrue);
    expect(b.featuresOff, {AppFeature.sponsor.id});
  });

  test('认不出的模块 id 直接忽略', () async {
    final st = await fresh();
    st.setFeature('no-such-module', false);
    expect(st.featuresOff, isEmpty);
    expect(st.featureOn('no-such-module'), isTrue, reason: '不认识的 id 当没关');
    expect(appFeatureById('no-such-module'), isNull);
  });

  test('偏好里的脏 id 被过滤掉', () async {
    SharedPreferences.setMockInitialValues({
      'featuresOff': ['rank', 'gone-module'],
    });
    final st = await fresh();
    expect(st.featuresOff, {AppFeature.rank.id});
    expect(st.featureEnabled(AppFeature.rank), isFalse);
  });
}
