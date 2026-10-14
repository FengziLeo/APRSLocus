import 'package:aprslocus/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「连接后由用户手动确认才开始上报」的行为回归。
///
/// 用户要求：无论用哪种方式定位，**连上服务器后不要自动上报**，必须由用户手动
/// 点一下正式的「开始上报」按钮、确认坐标有效之后才开始。这条约束针对
/// **本次连接**（`beaconArmed`）。
///
/// 2026-10-14 用户补充：「如果是**计划外**断开，可以直接重连」——
///   * 用户自己发起的连接 / 断开（`_plannedLinkChange()`，由 toggleConnect 与
///     factoryReset 调用）→ 确认作废，必须重新确认；
///   * 链路自己掉线又自动重连（以及重开 App）→ 确认**保留**，不再要求重新确认
///     （否则链路一抖，界面与常驻通知就跳回「待确认上报」，用户报的
///     「反复弹出待确认上报」就是这么来的）。
///
/// 关键点：`beaconArmed` **不持久化**。持久化就等于「确认一次、以后永远自动」，
/// 又绕回用户反对的行为，所以这里也要守住「重启后仍是未确认」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// 一个「链路已连、信标已开、本轮已定位、未确认」的状态。
  /// `connected` 通过真实翻转口子 [AppState.debugSetLinkUp] 置起（与生产同一条
  /// 路径）；未确认来自字段初值 `beaconArmed = false` —— 翻转本身不再复位确认，
  /// 这正是本轮要守住的新规矩（见文件头注释）。
  Future<AppState> connectedFresh() async {
    final st = AppState();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    st.beaconEnabled = true;
    st.dataSource = AppState.srcAprsIs;
    // 本轮真实定位：给坐标 + 打开上报闸（缺一不可，见 myPositionReportable）
    st.myHasFix = true;
    st.myLat = 39.9075;
    st.myLng = 116.3972;
    st.debugSetFreshFix();
    // 从断到连：这是**计划外**的连接变动，不该动确认（初值就是 false）
    st.debugSetLinkUp(AppState.srcAprsIs, true);
    return st;
  }

  group('连接后手动确认才上报', () {
    test('全新连接：未确认前不能自动上报，报 needConfirm 这一档', () async {
      final st = await connectedFresh();

      expect(st.connected, isTrue);
      expect(st.beaconArmed, isFalse, reason: '连上后必须处于「待确认」，不能自动上报');
      expect(st.canAutoBeacon, isFalse,
          reason: '未确认就能自动上报 —— 正是用户反对的「连上就自动上报」');
      expect(st.beaconPhase, BeaconPhase.needConfirm,
          reason: '不能发时必须报告原因（needConfirm），而不是继续倒计时');

      st.dispose();
    });

    test('点「开始上报」后：本次连接内放行自动上报', () async {
      final st = await connectedFresh();

      st.beginReporting();

      expect(st.beaconArmed, isTrue);
      expect(st.canAutoBeacon, isTrue, reason: '确认之后自动上报要真的能进行');
      expect(st.beaconPhase, isNot(BeaconPhase.needConfirm));

      st.dispose();
    });

    test('计划外断开又自愈：确认保留，不需要重新确认，直接续上报', () async {
      final st = await connectedFresh();
      st.beginReporting();
      expect(st.beaconArmed, isTrue);

      // 链路抖动：断 → 自动重连（没有用户动作）
      st.debugSetLinkUp(AppState.srcAprsIs, false);
      st.debugSetLinkUp(AppState.srcAprsIs, true);

      expect(st.beaconArmed, isTrue,
          reason: '计划外掉线自愈不能抹掉用户已做的确认（用户要求：计划外断开可以直接重连）');
      expect(st.canAutoBeacon, isTrue, reason: '自愈后要能接着上报，不再让用户点一遍');
      expect(st.beaconPhase, isNot(BeaconPhase.needConfirm),
          reason: '反复跳回 needConfirm 就是用户报的「反复提示确认上报」');

      st.dispose();
    });

    test('用户主动断开再连：确认被复位，必须重新确认', () async {
      final st = await connectedFresh();
      st.beginReporting();
      expect(st.beaconArmed, isTrue);

      // 用户自己点了「断开」，之后又点「连接」—— 都是计划内动作
      st.debugPlannedLinkChange(disconnecting: true);
      st.debugSetLinkUp(AppState.srcAprsIs, false);
      st.debugPlannedLinkChange(disconnecting: false);
      st.debugSetLinkUp(AppState.srcAprsIs, true);

      expect(st.beaconArmed, isFalse, reason: '新连接不能继承上一次的确认');
      expect(st.canAutoBeacon, isFalse);
      expect(st.beaconPhase, BeaconPhase.needConfirm);

      st.dispose();
    });

    test('重开 App：确认不持久化，仍是未确认', () async {
      final st = AppState();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(st.beaconArmed, isFalse,
          reason: '确认一旦持久化，就等于「确认一次、以后永远自动」');

      st.dispose();
    });

    test('beginReporting 会顺带打开自动上报总开关', () async {
      final st = await connectedFresh();
      st.beaconEnabled = false;
      expect(st.canAutoBeacon, isFalse);

      st.beginReporting();

      expect(st.beaconEnabled, isTrue, reason: '「开始上报」应打开自动上报总开关');
      expect(st.canAutoBeacon, isTrue);

      st.dispose();
    });

    test('手动「立即上报」不受连接闸影响：但按钮门槛是同一条 myPositionReportable',
        () async {
      final st = await connectedFresh();
      expect(st.beaconArmed, isFalse);

      // 未确认也能手动发一次（这是显式动作，不受「开始上报」闸约束）
      expect(st.myPositionReportable, isTrue);
      final before = st.beaconsSent;
      st.sendBeacon();
      expect(st.beaconsSent, before + 1,
          reason: '手动上报是用户显式动作，不该被连接确认闸挡住');

      st.dispose();
    });
  });
}
