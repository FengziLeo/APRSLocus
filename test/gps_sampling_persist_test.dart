/// GPS 采样间隔「能选、能记住、真能到原生」的回归测试。
///
/// 用户要求：「定位上报，用户可自调 GPS 采样率」。这条链有三段 —— 偏好 → 定位服务
/// → 原生 `requestLocationUpdates`。少任何一段的表现都是「设置里能选，实际还是 1 秒」，
/// 编译与 analyze 都过得去，界面上也看不出来，所以钉在这里。
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

  test('默认 1 秒', () async {
    final st = await fresh();
    expect(st.gpsIntervalSec, 1);
    expect(st.loc.samplingMs, 1000);
  });

  test('选过之后落盘：新实例能读回来，并且交给了定位服务', () async {
    final a = await fresh();
    a.setGpsIntervalSec(10);
    expect(a.gpsIntervalSec, 10);
    expect(a.loc.samplingMs, 10000, reason: '运行中的服务要立刻按新间隔采样');
    await a.persistNow();

    final b = await fresh();
    expect(b.gpsIntervalSec, 10, reason: '冷启动后省电那一档该还在');
    expect(b.loc.samplingMs, 10000, reason: '启动服务时要带上这一档');
  });

  test('档位之外的值不认，保留原来的那一档', () async {
    final st = await fresh();
    st.setGpsIntervalSec(5);
    st.setGpsIntervalSec(7); // 不在 gpsSampleChoices 里
    st.setGpsIntervalSec(0);
    expect(st.gpsIntervalSec, 5);
    expect(st.loc.samplingMs, 5000);
  });

  test('偏好文件里是脏值也回落到默认', () async {
    SharedPreferences.setMockInitialValues({'gpsIntervalSec': 7});
    final st = await fresh();
    expect(st.gpsIntervalSec, 1);
    expect(st.loc.samplingMs, 1000);
  });

  test('六档都认', () async {
    final st = await fresh();
    for (final v in AppState.gpsSampleChoices) {
      st.setGpsIntervalSec(v);
      expect(st.gpsIntervalSec, v);
    }
  });
}
