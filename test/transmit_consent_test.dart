import 'package:aprslocus/consent.dart';
import 'package:aprslocus/state.dart';
import 'package:aprslocus/terms_version.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 上传/发射的「单独同意」（用户协议 V2.0 附件一）的行为回归。
///
/// 这份协议不是一句「我同意」就完事，它要求四件事同时在代码里成立：
///   1. 上传/发射功能默认关，开启前必须单独同意（5.1 / 5.3）；
///   2. 同意按**功能项**记，勾哪项才签哪项（附件一的三个方框）；
///   3. 撤回与授权在同一层级，撤回后**立即**停止发送新的数据（5.2 / 5.5）；
///   4. 同意的行为要留日志（时间 + 功能项 + 告知文本版本），日志可单独清除，
///      清日志不等于撤回（5.4）。
///
/// 这个文件把上面四条各钉一遍。最容易漏的是第 3 条 —— 撤回如果只是写进日志、
/// 而发送口子没读同一份状态，界面显示「已撤回」、报文却照发，且不会报任何错。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// 一个刚启动的状态（构造里的 _loadPrefs 是异步的，等它落地）。
  Future<AppState> fresh() async {
    final st = AppState();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return st;
  }

  group('默认与需要的范围', () {
    test('默认没有同意：APRS-IS 链路在用时需要「信标上传」这一项', () async {
      final st = await fresh();

      expect(st.aprsIsOn, isTrue, reason: '默认来源就是 APRS-IS');
      expect(st.beaconConsentScopes, {ConsentScope.internet});
      expect(st.consentSatisfied, isFalse);
      expect(st.canAutoBeacon, isFalse,
          reason: '没签单独同意就绝不能自动把位置发出去');
      expect(st.consent.events, isEmpty);
    });

    test('只开射频来源时，需要的是「射频发射」那一项', () async {
      final st = await fresh();
      st.enabledSources
        ..clear()
        ..add(AppState.srcTnc);

      expect(st.beaconConsentScopes, {ConsentScope.rf});
    });

    test('两条链路都在用时，两项都要', () async {
      final st = await fresh();
      st.enabledSources.add(AppState.srcTnc);

      expect(st.beaconConsentScopes,
          {ConsentScope.internet, ConsentScope.rf});
      st.debugGrantConsent({ConsentScope.internet});
      expect(st.consentSatisfied, isFalse, reason: '只签一项不够');
      st.debugGrantConsent({ConsentScope.rf});
      expect(st.consentSatisfied, isTrue);
    });
  });

  group('开启前要签，签完接着开', () {
    test('拨开自动上报：先挂起同意书，开关不动', () async {
      final st = await fresh();
      st.beaconEnabled = false;

      st.setBeaconEnabled(true);

      expect(st.pendingConsent, {ConsentScope.internet},
          reason: '外壳据此整页显示同意书');
      expect(st.beaconEnabled, isFalse, reason: '没签之前开关不能真的打开');
      expect(st.hasConsent(ConsentScope.internet), isFalse);
    });

    test('勾选并确认后：同意落库，并且把开关真的打开', () async {
      final st = await fresh();
      st.beaconEnabled = false;
      st.setBeaconEnabled(true);

      await st.acceptConsent({ConsentScope.internet});

      expect(st.pendingConsent, isEmpty);
      expect(st.hasConsent(ConsentScope.internet), isTrue);
      expect(st.beaconEnabled, isTrue, reason: '签完要接着把用户点的那个开关打开');
      final ev = st.consent.events.single;
      expect(ev.scope, ConsentScope.internet);
      expect(ev.granted, isTrue);
      expect(ev.version, kTermsVersion, reason: '日志要记下告知文本的版本');
    });

    test('用户故意只勾了别的项：不替他打开对应功能', () async {
      final st = await fresh();
      st.beaconEnabled = false;
      st.setBeaconEnabled(true);

      // 只勾「射频发射」——互联网上传那一项没签
      await st.acceptConsent({ConsentScope.rf});

      expect(st.hasConsent(ConsentScope.rf), isTrue);
      expect(st.hasConsent(ConsentScope.internet), isFalse);
      expect(st.beaconEnabled, isFalse,
          reason: '没签的那一项对应的功能不能因为「点了同意」就打开');
      expect(st.consentSatisfied, isFalse);
    });

    test('选择「暂不开启」：什么都不记，也不改变开关', () async {
      final st = await fresh();
      st.beaconEnabled = false;
      st.setBeaconEnabled(true);

      st.declineConsent();

      expect(st.pendingConsent, isEmpty);
      expect(st.hasConsent(ConsentScope.internet), isFalse);
      expect(st.consent.events, isEmpty);
      expect(st.beaconEnabled, isFalse);
    });
  });

  group('撤回：授权与撤回同层，撤回即停', () {
    test('撤回后立刻不满足条件，日志里留下一条撤回', () async {
      final st = await fresh();
      st.debugGrantConsent();
      expect(st.consentSatisfied, isTrue);

      await st.revokeConsent(ConsentScope.internet);

      expect(st.hasConsent(ConsentScope.internet), isFalse);
      expect(st.consentSatisfied, isFalse);
      expect(st.canAutoBeacon, isFalse, reason: '撤回后不许再自动发新的数据');
      final ev = st.consent.events.single;
      expect(ev.granted, isFalse, reason: '撤回也要记一条（什么时候撤的同样是事实）');
      expect(ev.version, kTermsVersion);
    });

    test('撤回后手动上报也发不出去', () async {
      final st = await fresh();
      st.myHasFix = true;
      st.myLat = 39.9075;
      st.myLng = 116.3972;
      st.debugSetFreshFix();
      st.beaconEnabled = true;

      st.sendBeacon(); // 没同意：一个字节都不发
      expect(st.packets, isEmpty);
      expect(st.pendingConsent, {ConsentScope.internet},
          reason: '手动上报撞上闸门时要顺势把同意书摆出来');

      await st.acceptConsent({ConsentScope.internet});
      st.sendBeacon();
      expect(st.packets, isNotEmpty, reason: '签过之后手动上报要照常发');
    });
  });

  group('日志', () {
    test('重复同意不重复记；清日志不等于撤回', () async {
      final st = await fresh();
      await st.acceptConsent({ConsentScope.internet});
      await st.acceptConsent({ConsentScope.internet});

      expect(st.consent.events.length, 1, reason: '状态没变就不该再记一条');

      await st.clearConsentLog();

      expect(st.consent.events, isEmpty);
      expect(st.hasConsent(ConsentScope.internet), isTrue,
          reason: '协议 5.4：清日志只清日志，已经作出的同意不受影响');
    });
  });
}
