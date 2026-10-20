import 'package:flutter_test/flutter_test.dart';

import 'package:aprslocus/min_version.dart';
import 'package:aprslocus/version_compare.dart';

/// ─── 官网最低版本（`assets/min_version.json`）───
///
/// 这份逻辑的两种错法都很难在真机上发现：
///   * 该拦的时候不拦（版本号写坏、字段名拼错、JSON 坏掉）—— 编译、analyze、
///     启动全都正常，只是闸门静静地不落下；
///   * 不该拦的时候拦（比较方向写反、`blocks` 里漏了 `active`）—— 所有人开不了
///     应用，而且这一发出去就是事故。
/// 所以把解析与判定的边界全钉在这里，包括"失败放行"这一条底线。
void main() {
  group('parse', () {
    test('正常文件：三个字段都读到', () {
      final mv = MinVersion.parse('{"updated":"2026-10-20",'
          '"minVersion":"2.1.20","reason":"2.1.20 之前的版本有崩溃"}');
      expect(mv, isNotNull);
      expect(mv!.minVersion, '2.1.20');
      expect(mv.reason, '2.1.20 之前的版本有崩溃');
      expect(mv.updated, '2026-10-20');
      expect(mv.active, isTrue);
    });

    test('前导 v 被去掉（官网手写时很常见）', () {
      expect(MinVersion.parse('{"minVersion":"v2.1.20"}')!.minVersion, '2.1.20');
      expect(MinVersion.parse('{"minVersion":"V2.1.20"}')!.minVersion, '2.1.20');
    });

    test('下划线写法也行（版本比较按点/下划线分段）', () {
      expect(MinVersion.parse('{"minVersion":"2_1_20"}')!.minVersion, '2_1_20');
    });

    test('minVersion 缺失或为空 = 不设下限', () {
      for (final t in ['{}', '{"minVersion":""}', '{"minVersion":"   "}',
        '{"minVersion":null}', '{"updated":"2026-10-20"}']) {
        final mv = MinVersion.parse(t);
        expect(mv, isNotNull, reason: t);
        expect(mv!.active, isFalse, reason: t);
        expect(mv.blocks('2.1.25'), isFalse, reason: t);
      }
    });

    test('兼容 snake_case 写法', () {
      expect(MinVersion.parse('{"min_version":"2.1.20"}')!.minVersion, '2.1.20');
    });

    test('坏 JSON / 非对象 = null（调用方按"没查到"处理）', () {
      expect(MinVersion.parse(''), isNull);
      expect(MinVersion.parse('{'), isNull);
      expect(MinVersion.parse('[]'), isNull);
      expect(MinVersion.parse('"2.1.20"'), isNull);
      expect(MinVersion.parse('null'), isNull);
    });
  });

  group('blocks', () {
    final mv = const MinVersion(minVersion: '2.1.20');

    test('低于下限要拦', () {
      expect(mv.blocks('2.1.19'), isTrue);
      expect(mv.blocks('2.1.2'), isTrue);   // 数字段比较，不是字符串比较
      expect(mv.blocks('2.0.99'), isTrue);
      expect(mv.blocks('1.9.9'), isTrue);
      expect(mv.blocks('v2.1.19'), isTrue);
    });

    test('等于或高于下限不拦', () {
      expect(mv.blocks('2.1.20'), isFalse);
      expect(mv.blocks('2.1.21'), isFalse);
      expect(mv.blocks('2.2.0'), isFalse);
      expect(mv.blocks('3.0.0'), isFalse);
    });

    test('没设下限时永远不拦', () {
      expect(const MinVersion().blocks('0.0.1'), isFalse);
    });

    test('下限写不成版本（手滑）时放行 —— 宁漏拦不锁人', () {
      expect(const MinVersion(minVersion: 'abc').blocks('2.1.25'), isFalse);
      expect(const MinVersion(minVersion: '2.x').blocks('2.1.25'), isFalse);
    });
  });

  group('compareVersions（与更新页同一套规则）', () {
    test('数字段 > 字母段 > 缺段', () {
      expect(compareVersions('2.1.6', '2.1.5'), greaterThan(0));
      expect(compareVersions('2.1.5.b', '2.1.5'), greaterThan(0));
      expect(compareVersions('2.1.6', '2.1.5.b'), greaterThan(0));
      expect(compareVersions('2.1', '2.1.0'), lessThan(0));
    });

    test('相等与 v 前缀', () {
      expect(compareVersions('v2.1.25', '2.1.25'), 0);
      expect(compareVersions('2.1.25', '2.1.25'), 0);
    });
  });
}
