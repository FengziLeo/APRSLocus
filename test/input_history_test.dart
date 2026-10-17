/// 输入框历史（数据包页搜索词 / 连接设置服务器地址）的回归测试。
///
/// 用户要求：这两个输入框要有「最近用过的」列表，点开能挑一条。
/// 历史活在 [AppState] 里并落盘 —— 它本来就是用来省重敲的，退出页面就清空
/// 等于没有。
///
/// 为什么钉在 CI：这类错**编译能过、analyze 也全绿**，只表现成「历史怎么空了」
/// 或「同一条出现八遍」。四条同样哑的错一并钉住：
///   * 重复的记账（同一个词连着用两次）不该挤掉别的条目；
///   * 上限真的生效（否则偏好文件会越写越长）；
///   * 两个输入框的历史互不串（枚举分错了只表现为「服务器里出现搜索词」）；
///   * 落盘之后真的能读回来、清空之后真的存成空。
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

  test('默认没有历史', () async {
    final st = await fresh();
    expect(st.packetSearchHistory, isEmpty);
    expect(st.serverHistory, isEmpty);
  });

  test('记一条就排在最前，空白值不记', () async {
    final st = await fresh();
    st.rememberInput(InputHistory.packetSearch, 'BG7');
    st.rememberInput(InputHistory.packetSearch, '  BG5  ');
    st.rememberInput(InputHistory.packetSearch, '   ');
    expect(st.packetSearchHistory, ['BG5', 'BG7']);
  });

  test('同一条再记一次只提前，不重复', () async {
    final st = await fresh();
    st.rememberInput(InputHistory.packetSearch, 'A');
    st.rememberInput(InputHistory.packetSearch, 'B');
    st.rememberInput(InputHistory.packetSearch, 'A');
    expect(st.packetSearchHistory, ['A', 'B']);
  });

  test('超过上限就丢掉最旧的一条', () async {
    final st = await fresh();
    for (var i = 0; i < AppState.historyLimit + 3; i++) {
      st.rememberInput(InputHistory.packetSearch, 'q$i');
    }
    expect(st.packetSearchHistory.length, AppState.historyLimit);
    expect(st.packetSearchHistory.first,
        'q${AppState.historyLimit + 2}');
    expect(st.packetSearchHistory.contains('q0'), isFalse);
  });

  test('两个输入框的历史互不串', () async {
    final st = await fresh();
    st.rememberInput(InputHistory.server, 'rotate.aprs2.net');
    st.rememberInput(InputHistory.packetSearch, 'BG7');
    expect(st.serverHistory, ['rotate.aprs2.net']);
    expect(st.packetSearchHistory, ['BG7']);
  });

  test('删一条 / 清空', () async {
    final st = await fresh();
    st.rememberInput(InputHistory.server, 'a.example');
    st.rememberInput(InputHistory.server, 'b.example');
    st.forgetInput(InputHistory.server, 'a.example');
    expect(st.serverHistory, ['b.example']);
    st.clearInputHistory(InputHistory.server);
    expect(st.serverHistory, isEmpty);
  });

  test('落盘：新实例能读回来，清空也真的存下去', () async {
    final a = await fresh();
    a.rememberInput(InputHistory.server, 'rotate.aprs2.net');
    a.rememberInput(InputHistory.packetSearch, 'BG7LZQ');
    await a.persistNow();

    final b = await fresh();
    expect(b.serverHistory, ['rotate.aprs2.net']);
    expect(b.packetSearchHistory, ['BG7LZQ']);

    b.clearInputHistory(InputHistory.server);
    await b.persistNow();
    final c = await fresh();
    expect(c.serverHistory, isEmpty, reason: '清空之后不该又冒出来');
    expect(c.packetSearchHistory, ['BG7LZQ']);
  });
}
