import 'package:aprslocus/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「打开软件时」三档的行为回归（用户 2026-10-20）。
///
/// 用户原话：「定位上报可以进入软件后自动连接服务器或者直接进入上报流程
/// （选项 1 不做操作 2 自动连接服务器 3 自动进入上报，需要告知用户确定是否
/// 开启，默认关闭，打开需告知）」。
///
/// 这里守住三件事：
///   * 默认是 0（不做操作）—— 开机就联网、就发位置不能替他决定；
///   * 1（自动连接）只连接，绝不顺手把上报放行；
///   * 2（自动上报）才进入上报流程，且照样过「单独同意」那道闸。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppState> fresh() async {
    final st = AppState();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    st.oobeDone = true;
    return st;
  }

  group('打开软件时的三档', () {
    test('默认是 0：开启动时什么都不做', () async {
      final st = await fresh();
      expect(st.autoStartMode, 0);

      final before = st.beaconsSent;
      await st.autoStartOnLaunch();

      expect(st.beaconArmed, isFalse, reason: '默认档不能放行上报');
      expect(st.beaconsSent, before, reason: '默认档不能发位置');
      expect(st.connectNoServerSeq, 0, reason: '默认档连服务器都不该碰');

      st.dispose();
    });

    test('非法值夹回 0..2', () async {
      final st = await fresh();
      st.setAutoStartMode(9);
      expect(st.autoStartMode, 2);
      st.setAutoStartMode(-3);
      expect(st.autoStartMode, 0);

      st.dispose();
    });

    test('1（自动连接）：只连服务器，不放行上报', () async {
      final st = await fresh();
      // 告知先签掉，才轮得到「地址没填」那一步（否则第一个闸就把它拦下了）
      st.dataNoticeAccepted = true;
      st.setAutoStartMode(1);
      final before = st.beaconsSent;

      await st.autoStartOnLaunch();

      // 测试环境没填服务器地址：toggleConnect 会拦在「未配置」那一步，
      // 这正好用来证明它**确实去连了**（序号 +1）而没有真的建连。
      expect(st.connectNoServerSeq, 1, reason: '这一档要真的去连接服务器');
      expect(st.beaconArmed, isFalse, reason: '自动连接不等于自动上报');
      expect(st.beaconsSent, before, reason: '这一档不能发位置');
      expect(st.connecting, isFalse);

      st.dispose();
    });

    test('2（自动上报）：连过之后直接进入上报流程', () async {
      final st = await fresh();
      st.debugGrantConsent(); // 单独同意已签（否则下面会被同意闸挡住）
      st.setAutoStartMode(2);

      await st.autoStartOnLaunch();

      expect(st.beaconArmed, isTrue, reason: '这一档要放行本次连接的自动上报');
      expect(st.beaconEnabled, isTrue, reason: '自动上报总开关要跟着打开');
      expect(st.beaconPhase, isNot(BeaconPhase.needConfirm));

      st.dispose();
    });

    test('2 也过单独同意：没签就不打开上报', () async {
      final st = await fresh();
      st.setAutoStartMode(2);
      // 没签同意：总开关原本是开的（默认 true），先摆成关，才能看清「开不回来」
      st.beaconEnabled = false;

      st.startReportingAuto();

      expect(st.pendingConsent, isNotEmpty, reason: '要先让用户签同意书');
      expect(st.beaconEnabled, isFalse, reason: '没签就不替他把上报打开');
      expect(st.beaconArmed, isFalse);

      st.dispose();
    });
  });
}
