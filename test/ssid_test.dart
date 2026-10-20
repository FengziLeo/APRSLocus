/// 呼号后缀（SSID）能自己输入 —— 含字母后缀的回归测试。
///
/// 用户要求：「ssid 支持自定义输入」。原来只在弹层里给 0–15 十六个格子，而
/// 我们自己的 APRSNETCN 服务器收字母后缀（`BI1QKA-B` 这种），所以后缀改成
/// **字符串**。这类改动编译能过、analyze 也全绿，错了只表现成三种症状：
///
/// * 老用户的数字后缀升级后丢了（偏好里存的是整数）；
/// * 脏字符串被原样拼进呼号发出去（`BG7LZQ-zzz`）；
/// * `-0` 变成一个看着有、实际没有的后缀。
library;

import 'package:aprslocus/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppState> fresh() async {
    final st = AppState();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return st;
  }

  test('空后缀就是纯呼号', () async {
    final st = await fresh();
    st.myCall = 'BG7LZQ';
    expect(st.mySsid, '');
    expect(st.myFullCall, 'BG7LZQ');
  });

  test('数字后缀照旧', () async {
    final st = await fresh();
    st.myCall = 'BG7LZQ';
    expect(st.setSsid('9'), isTrue);
    expect(st.myFullCall, 'BG7LZQ-9');
  });

  test('字母后缀可以用，大小写与前导 - 都规整掉', () async {
    final st = await fresh();
    st.myCall = 'BI1QKA';
    expect(st.setSsid('-b'), isTrue);
    expect(st.mySsid, 'B');
    expect(st.myFullCall, 'BI1QKA-B');
  });

  test('两位后缀可以', () async {
    final st = await fresh();
    st.myCall = 'BG7LZQ';
    expect(st.setSsid('ab'), isTrue);
    expect(st.myFullCall, 'BG7LZQ-AB');
  });

  test('0 等于不要后缀（-0 与无后缀是一回事）', () async {
    expect(AppState.normalizeSsid('0'), '');
    expect(AppState.normalizeSsid('-0'), '');
  });

  test('形状不对的一律不接受，且不改动已有值', () async {
    final st = await fresh();
    st.myCall = 'BG7LZQ';
    st.setSsid('7');
    for (final bad in ['', '   ', '!!!', '123', 'a-b', '中']) {
      if (bad.trim().isEmpty) continue; // 空串是合法的「不要后缀」
      expect(st.setSsid(bad), isFalse, reason: '不该接受「$bad」');
      expect(st.mySsid, '7', reason: '被拒绝时不能把原值改坏');
    }
  });

  test('清空后缀', () async {
    final st = await fresh();
    st.myCall = 'BG7LZQ';
    st.setSsid('B');
    expect(st.setSsid(''), isTrue);
    expect(st.myFullCall, 'BG7LZQ');
  });

  test('落盘后新实例读得回来', () async {
    final a = await fresh();
    a.myCall = 'BI1QKA';
    a.setSsid('B');
    await a.persistNow();

    final b = await fresh();
    expect(b.mySsid, 'B');
    expect(b.myFullCall, 'BI1QKA-B');
  });

  test('老版本存的是整数：升级后变成字符串后缀', () async {
    SharedPreferences.setMockInitialValues({'mySsid': 3});
    final st = await fresh();
    expect(st.mySsid, '3');
    expect(st.myFullCall, '${st.myCall}-3');
  });

  test('老版本的 0（无后缀）迁移成空串', () async {
    SharedPreferences.setMockInitialValues({'mySsid': 0});
    final st = await fresh();
    expect(st.mySsid, '');
  });

  test('偏好里是脏字符串时回到无后缀', () async {
    SharedPreferences.setMockInitialValues({'mySsid': 'zzz'});
    final st = await fresh();
    expect(st.mySsid, '');
  });
}
