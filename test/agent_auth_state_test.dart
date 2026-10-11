/// 智能体「需授权」这道闸在 AppState 上的行为回归。
///
/// 智能体不对普通用户开放：开关被按下时必须**真的**被拦住，而不是"看起来弹了个页
/// 却照样开启"。几类错误在编译/analyze 下全绿，只有点下去才暴露：
///   * 签完告知后忘了接授权这一道（点开关直接开）；
///   * 白名单拉不到时把"未知"当成"放行"（锁没钥匙却开了）；
///   * 备份/旧版本带进来的 enabled=true 没被兜底关掉（绕过申请流程）。
/// 所以这里驱动真实的 [AppState] 方法逐条钉住。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aprslocus/agent.dart';
import 'package:aprslocus/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const allowJson =
      '{"updated":"2026-10-03","entries":[{"call":"BG7LZQ","note":"作者"}]}';

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// AppState 的构造器里有异步的 `_loadPrefs()`（从 prefs 读回
  /// `agentNoticeAccepted` 等）。测试里若在它落地前就手改这些字段，会被它覆盖，
  /// 于是测的是"竞态"而不是闸门本身。这里等它读完再返回。
  Future<AppState> newState() async {
    final st = AppState();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    return st;
  }

  test('默认未授权：点开关只弹授权页，不真正启用', () async {
    final st = await newState();
    st.myCall = 'BA1AAA';
    st.agentNoticeAccepted = true;

    st.setAgentEnabled(true);

    expect(st.agentAllowed, isFalse);
    expect(st.pendingAgentAuth, isTrue, reason: '应弹授权/申请页');
    expect(AgentService.instance.config.enabled, isFalse,
        reason: '未授权绝不能真的开');
  });

  test('先签告知再点开关：签完继续走到授权这道闸', () async {
    final st = await newState();
    st.myCall = 'BA1AAA';

    st.setAgentEnabled(true); // 未签告知
    expect(st.pendingAgentNotice, isTrue);
    expect(st.pendingAgentAuth, isFalse);

    st.acceptAgentNotice(); // 签完 → 继续尝试启用
    expect(st.pendingAgentNotice, isFalse);
    expect(st.pendingAgentAuth, isTrue, reason: '授权这道闸要接得住');
    expect(AgentService.instance.config.enabled, isFalse);
  });

  test('名单拉不到（无缓存）→ 判为未授权，申请也返回 false', () async {
    final st = await newState();
    st.myCall = 'BG7LZQ'; // 就算呼号在官网名单里，此刻也拉不到
    st.agentNoticeAccepted = true;

    final ok = await st.submitAgentAuthApplication();

    expect(ok, isFalse, reason: '锁没钥匙不该开');
    expect(st.agentAllowed, isFalse);
  });

  test('曾成功拉到过名单 → 离线按缓存判：授权者断网也能用', () async {
    SharedPreferences.setMockInitialValues({
      'agentAllowCacheJson': allowJson,
      'agentAllowCheckedAt': DateTime.now().millisecondsSinceEpoch,
    });
    final st = await newState();
    st.myCall = 'BG7LZQ';
    st.agentNoticeAccepted = true;

    await st.recheckAgentAllow(); // 不 force，且未过期 → 直接用缓存，不联网

    expect(st.agentAllowed, isTrue);
    expect(AgentService.instance.config.enabled, isFalse,
        reason: '重查只判授权，不替你按下开关');
  });

  test('缓存里没有本机呼号 → 未授权', () async {
    SharedPreferences.setMockInitialValues({
      'agentAllowCacheJson': allowJson,
      'agentAllowCheckedAt': DateTime.now().millisecondsSinceEpoch,
    });
    final st = await newState();
    st.myCall = 'BA1AAA';

    await st.recheckAgentAllow();

    expect(st.agentAllowed, isFalse);
  });

  test('兜底强制关闭：确认未授权时，把已开的智能体关掉', () async {
    SharedPreferences.setMockInitialValues({
      'agentAllowCacheJson': allowJson,
      'agentAllowCheckedAt': DateTime.now().millisecondsSinceEpoch,
    });
    final st = await newState();
    st.myCall = 'BA1AAA'; // 不在名单里
    AgentService.instance.config.enabled = true; // 假装是备份/旧版本带进来的

    await st.recheckAgentAllow();

    expect(st.agentAllowed, isFalse);
    expect(AgentService.instance.config.enabled, isFalse,
        reason: '确认未授权后必须强制关闭，防绕过');
  });

  test('提交申请时已在名单里 → 关页并真正启用', () async {
    SharedPreferences.setMockInitialValues({
      'agentAllowCacheJson': allowJson,
      'agentAllowCheckedAt': DateTime.now().millisecondsSinceEpoch,
    });
    final st = await newState();
    st.myCall = 'BG7LZQ';
    st.agentNoticeAccepted = true;
    st.pendingAgentAuth = true;

    final ok = await st.submitAgentAuthApplication();

    expect(ok, isTrue);
    expect(st.pendingAgentAuth, isFalse, reason: '已授权应关掉申请页');
    expect(AgentService.instance.config.enabled, isTrue, reason: '此刻才真正启用');
  });
}
