import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aprslocus/huangyan_island.dart';
import 'package:aprslocus/l10n/app_localizations.dart';

/// 黄岩岛隐藏台站彩蛋。
///
/// 这条台站**永不进 `AppState.stations`**（所以列表正常翻是翻不到的），
/// 只在搜索命中关键词时临时注入。这里锁住三件事：
///   1. 关键词命中面（简繁/拼音/呼号/英文名），且普通词不误触发；
///   2. 合成台站本身（呼号、坐标、面板识别用的 isHuangyanCall）；
///   3. 介绍网页（HTML）确实带上了呼号、坐标与正文文案，且 6 语言都有词。
/// 这些都不会在编译/analyze 时暴露，只有主动搜索才会用到。
void main() {
  final s = lookupAppLocalizations(const Locale('zh'));

  group('黄岩岛彩蛋 · 搜索命中面', () {
    test('命中：简繁中文 / 拼音 / 英文名 / 呼号 / 别称', () {
      for (final q in const [
        '黄岩岛',
        '黃岩島',
        '黄岩',
        'huangyan',
        'HuangYan',
        'BS7H',
        'bs7h',
        'Scarborough',
        'scarborough shoal',
        '民主礁',
      ]) {
        expect(isHuangyanQuery(q), isTrue, reason: '应命中：$q');
      }
    });

    test('命中：搜索词里夹带其它内容也算（contains）', () {
      expect(isHuangyanQuery(' 黄岩岛 '), isTrue);
      expect(isHuangyanQuery('黄埔 黄岩岛'), isTrue);
    });

    test('不命中：空串与普通词不误触发（列表正常翻不会冒出来）', () {
      for (final q in const ['', '   ', 'BG', 'BH', '广州', '南沙', '北京', '海洋']) {
        expect(isHuangyanQuery(q), isFalse, reason: '不该命中：$q');
      }
    });
  });

  group('黄岩岛彩蛋 · 合成台站', () {
    test('呼号 BS7H，位置在岛屿坐标，且被面板识别为彩蛋', () {
      final st = huangyanStation(s);
      expect(st.call, 'BS7H');
      expect(isHuangyanCall(st.call), isTrue);
      // 大小写不敏感（面板容错）
      expect(isHuangyanCall('bs7h'), isTrue);
      expect(isHuangyanCall('BG7LZQ'), isFalse);
      // 黄岩岛大致坐标
      expect(st.lat, closeTo(15.15, 0.5));
      expect(st.lng, closeTo(117.77, 0.6));
      // 描述文案随语言取，非空，并写明「中国固有领土」
      expect(st.comment, isNotNull);
      expect(st.comment, contains('中国固有领土'));
    });
  });

  group('黄岩岛彩蛋 · 介绍网页', () {
    test('HTML 含呼号 / 坐标 / 标题，且是自包含 data URI', () {
      final html = huangyanIntroHtml(s);
      expect(html, contains('<!DOCTYPE html>'));
      expect(html, contains('BS7H'));
      expect(html, contains('15.1500°N 117.7667°E'));
      expect(html, contains(s.huangyanTitle));
      expect(html, contains(s.huangyanGeoHead));
      expect(html, contains(s.huangyanHistoryHead));
      expect(html, contains(s.huangyanHamHead));
      expect(html, contains(s.huangyanLegal));

      final url = huangyanIntroUrl(s);
      expect(url, startsWith('data:text/html;charset=utf-8,'));
      // 编码后不应含裸空格（否则某些 WebView 解析失败）
      expect(url.contains(' '), isFalse);
    });

    test('6 语言都具备全部标题/正文键（不会漏翻成空串）', () {
      const locales = [
        Locale('zh'),
        Locale('zh', 'TW'),
        Locale('en'),
        Locale('ja'),
        Locale('es'),
        Locale('id'),
      ];
      for (final locale in locales) {
        final ls = lookupAppLocalizations(locale);
        final html = huangyanIntroHtml(ls);
        for (final t in [
          ls.huangyanTitle,
          ls.huangyanGeoHead,
          ls.huangyanGeoBody,
          ls.huangyanHistoryHead,
          ls.huangyanHistory1,
          ls.huangyanHistory2,
          ls.huangyanHamHead,
          ls.huangyanHamBody,
          ls.huangyanLegal,
        ]) {
          expect(t.trim().isNotEmpty, isTrue, reason: '$locale 有空文案');
          expect(html.contains(t), isTrue, reason: '$locale 的网页缺少文案：$t');
        }
      }
    });
  });
}
