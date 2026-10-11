/// 智能体授权名单（白名单）的解析与命中判断回归测试。
///
/// 与黑名单（`blacklist_test.dart`）镜像对称，但方向相反 —— 黑名单"命中就拦"，
/// 白名单"命中才放"。价值同样全在**边界**上：
///   * 名单拉不到 / JSON 坏了 → 判为**未知**（调用方按"默认拒绝"处理，绝不自动放行）；
///   * 条目格式不对（小写呼号、空条目）→ **静默不授权**，不能"看起来在名单里"；
///   * 只写 `*` 的条目 → 必须作废，否则手滑一下就把智能体对所有人开放；
///   * 命中判断要大小写不敏感、去掉空白。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aprslocus/agent_allow.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('解析', () {
    test('正常名单', () {
      final al = AgentAllow.parse('''
{"updated":"2026-10-03","entries":[
  {"call":"BG7LZQ","note":"软件作者","at":"2026-10-03"},
  {"call":"BH7*","note":"测试"}]}''');
      expect(al, isNotNull);
      expect(al!.entries.length, 2);
      expect(al.entries.first.call, 'BG7LZQ');
      expect(al.updated, '2026-10-03');
    });

    test('坏 JSON / 结构不对 → null（调用方按"未知→未授权"处理）', () {
      expect(AgentAllow.parse('{ this is not json'), isNull);
      expect(AgentAllow.parse(''), isNull);
      expect(AgentAllow.parse('[]'), isNull);                // 顶层不是对象
      expect(AgentAllow.parse('{"updated":"x"}'), isNull);   // 没有 entries
    });

    test('没有 call 的条目被丢掉', () {
      final al = AgentAllow.parse(
          '{"entries":[{"note":"oops"},{"call":"A1AAA","note":"x"}]}')!;
      expect(al.entries.length, 1);
      expect(al.entries.single.call, 'A1AAA');
    });

    test('呼号统一大写（手写名单大小写不一致也不误事）', () {
      final al =
          AgentAllow.parse('{"entries":[{"call":"bg7lzq","note":"x"}]}')!;
      expect(al.entries.single.call, 'BG7LZQ');
      expect(al.allows('bg7lzq'), isTrue);
    });
  });

  group('授权判断', () {
    test('在名单里 → 放行（大小写/空白不敏感）', () {
      final al = AgentAllow.parse(
          '{"entries":[{"call":"BG7LZQ","note":"x"}]}')!;
      expect(al.allows('  bg7lzq '), isTrue);
    });

    test('不在名单里 → 不放行', () {
      final al = AgentAllow.parse(
          '{"entries":[{"call":"BG7LZQ","note":"x"}]}')!;
      expect(al.allows('BA1AAA'), isFalse);
      expect(al.allows(''), isFalse);
    });

    test('空名单 → 谁都不放行（默认拒绝）', () {
      final al = AgentAllow.parse('{"entries":[]}')!;
      expect(al.allows('BG7LZQ'), isFalse);
    });
  });

  group('呼号通配符（与黑名单同一套规则）', () {
    test('裸呼号 = 授权这个人（连他的各 SSID 一起）', () {
      final al = AgentAllow.parse(
          '{"entries":[{"call":"BG7LZQ","note":"人"}]}')!;
      for (final c in ['BG7LZQ', 'BG7LZQ-0', 'BG7LZQ-7', 'bg7lzq-15']) {
        expect(al.allows(c), isTrue, reason: '该放行：$c');
      }
      for (final c in ['BG7LZQ2', 'BG7LZQ-1A', 'BA7LZQ-9', 'BG7LZ']) {
        expect(al.allows(c), isFalse, reason: '不该放行：$c');
      }
    });

    test('带 SSID 的条目只授权那一台（精确）', () {
      final al = AgentAllow.parse(
          '{"entries":[{"call":"BG7LZQ-7","note":"一台"}]}')!;
      expect(al.allows('BG7LZQ-7'), isTrue);
      expect(al.allows('BG7LZQ'), isFalse, reason: '不带 SSID 的那个不该放行');
      expect(al.allows('BG7LZQ-9'), isFalse);
    });

    test('其他位置的 * 是任意串', () {
      final al = AgentAllow.parse(
          '{"entries":[{"call":"BH7*","note":"前缀"}]}')!;
      expect(al.allows('BH7GZB-3'), isTrue);
      expect(al.allows('BH7GZB'), isTrue);
      expect(al.allows('BG7LZQ'), isFalse);
    });

    test('只有通配符的条目被丢弃（防手滑把智能体对所有人开放）', () {
      final al = AgentAllow.parse('{"entries":['
          '{"call":"*","note":"oops"},'
          '{"call":"-*","note":"oops"},'
          '{"call":"BG7LZQ","note":"ok"}]}')!;
      expect(al.entries.length, 1, reason: '只该留下带真实呼号的那条');
      expect(al.allows('BA1AAA-1'), isFalse);
      expect(al.allows('BG7LZQ-1'), isTrue);
    });
  });

  group('申请邮箱', () {
    test('投递地址固定为 mc081208@163.com', () {
      expect(AgentAllow.kApplyEmail, 'mc081208@163.com');
    });
  });
}
