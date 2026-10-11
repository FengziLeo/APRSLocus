import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';
import 'models.dart';
import 'theme.dart';
import 'web_embed.dart';
import 'widgets.dart';

/// 黄岩岛彩蛋（隐藏台站）。
///
/// 台站列表**正常翻是翻不到的** —— 这条台站从不进 `AppState.stations`，
/// 只有搜索框命中「黄岩岛 / BS7H / 黄岩」等关键词时，才临时拼一条合成台站
/// 混入结果（见 [isHuangyanQuery] / [huangyanStation]）。所以它既不会污染
/// 台站统计、也不会出现在地图上，只有主动搜索的人才会碰到。
///
/// 命中后走的是**标准台站面板**（StationDetail）：复制坐标、查看地图、
/// 导航、QRZ / aprs.fi 一应俱全；面板顶部另加一张「黄岩岛」介绍卡，
/// 用内嵌网页渲染地理与历史由来（[huangyanIntroHtml]，复用 [WebEmbed]）。

/// 触发彩蛋的搜索词（小写比较，命中任意一个即注入）。
///
/// 覆盖简繁中文、拼音、呼号与英文名，避免用户「换种写法就搜不到」。
const List<String> huangyanKeywords = [
  '黄岩岛',
  '黃岩島',
  '黄岩',
  '黃岩',
  'huangyan',
  'bs7h',
  'scarborough',
  '民主礁',
];

/// 是否命中黄岩岛彩蛋搜索词。
bool isHuangyanQuery(String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return false;
  return huangyanKeywords.any(q.contains);
}

/// 该呼号是否为黄岩岛彩蛋台站（面板据此追加介绍卡）。
bool isHuangyanCall(String call) => call.toUpperCase() == 'BS7H';

/// 合成一条「黄岩岛」台站。
///
/// 呼号 BS7H 是黄岩岛的业余无线电 DXCC 实体前缀（1995 年由中外爱好者
/// 联合远征首次启用）。位置用岛屿中心经纬度；符号取 HF 网关（`&`），
/// 与「远海 HF 远征台」的定位一致。
Station huangyanStation(AppLocalizations s) => Station(
  call: 'BS7H',
  symbol: '&',
  alias: s.huangyanTitle,
  lat: 15.1500,
  lng: 117.7667,
  alt: 0,
  comment: s.huangyanShort,
  status: St.online,
  lastHeard: DateTime.now(),
  toCall: 'APRS',
);

/// 黄岩岛介绍卡（放在标准台站面板顶部）：标题 + 说明 + 介绍内容。
///
/// 支持内嵌网页的平台（Android / iOS / macOS）用 [WebEmbed] 渲染
/// [huangyanIntroHtml]；其余平台（Web / Linux / Windows）**不会**退化成
/// 一个打不开的「浏览器打开」按钮 —— 内容本就自带，直接原生文案渲染，
/// 保证任何平台上都看得到。
class HuangyanIntroCard extends StatelessWidget {
  const HuangyanIntroCard({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return SoftCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.anchor_rounded, size: 16, color: C.blue),
              const SizedBox(width: 6),
              Text(
                s.huangyanTitle,
                style: ts(13, c: C.blue, w: FontWeight.w800),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.huangyanBadge,
                  style: ts(10, c: C.grey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(s.huangyanTagline, style: ts(11, c: C.slate)),
          const SizedBox(height: 10),
          if (webEmbedSupported)
            WebEmbed(
              url: huangyanIntroUrl(s),
              html: huangyanIntroHtml(s),
              height: 300,
            )
          else
            _nativeIntro(s),
          const SizedBox(height: 8),
          Text(
            webEmbedSupported ? s.huangyanSourceHint : s.huangyanFootNote,
            style: ts(10, c: C.grey),
          ),
        ],
      ),
    );
  }

  /// 无内嵌网页能力时的原生兜底：与网页同源文案，分段展示。
  Widget _nativeIntro(AppLocalizations s) {
    Widget head(String t) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(t, style: ts(12, c: C.blue, w: FontWeight.w800)),
    );
    Widget body(String t) => Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Text(t, style: ts(12, c: C.slate)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        head(s.huangyanGeoHead),
        body(s.huangyanGeoBody),
        head(s.huangyanHistoryHead),
        body(s.huangyanHistory1),
        body(s.huangyanHistory2),
        head(s.huangyanHamHead),
        body(s.huangyanHamBody),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: C.greyBg,
            borderRadius: BorderRadius.circular(6),
            border: Border(left: BorderSide(color: C.blue, width: 3)),
          ),
          child: Text(s.huangyanLegal, style: ts(11, c: C.ink)),
        ),
      ],
    );
  }
}

/// 介绍页的 data URI（内嵌 HTML，Content-Type 显式声明以免中文乱码）。
String huangyanIntroUrl(AppLocalizations s) =>
    'data:text/html;charset=utf-8,${Uri.encodeComponent(huangyanIntroHtml(s))}';

/// 黄岩岛介绍网页（HTML）。
///
/// 用自包含的 HTML 渲染「地理 + 历史由来」，随界面语言切换文案（[s] 即当前
/// 语言）。配色直接取主题 token（[C] 已按深浅色适配），故本函数不依赖
/// `BuildContext`，可在任何地方生成。
String huangyanIntroHtml(AppLocalizations s) {
  String hex(Color c) {
    final r = (c.r * 255).round().clamp(0, 255);
    final g = (c.g * 255).round().clamp(0, 255);
    final b = (c.b * 255).round().clamp(0, 255);
    return '#${((r << 16) | (g << 8) | b).toRadixString(16).padLeft(6, '0')}';
  }

  final bg = hex(C.bg);
  final ink = hex(C.ink);
  final slate = hex(C.slate);
  final grey = hex(C.grey);
  final soft = hex(C.greyBg);
  final border = hex(C.border);
  final blue = hex(C.blue);
  final scheme = C.dark ? 'dark' : 'light';

  return '''
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root { color-scheme: $scheme; }
  body {
    margin: 0; padding: 16px;
    font-family: -apple-system, "PingFang SC", "Noto Sans SC",
                 "Microsoft YaHei", system-ui, sans-serif;
    background: $bg; color: $ink;
    font-size: 14px; line-height: 1.7; -webkit-text-size-adjust: 100%;
  }
  h1 { font-size: 19px; margin: 2px 0; letter-spacing: .3px; }
  .call { font-family: ui-monospace, Menlo, Consolas, monospace;
          color: $blue; font-weight: 700; letter-spacing: 1px; }
  .coord { color: $grey; font-size: 12px; margin-bottom: 12px;
           font-family: ui-monospace, Menlo, Consolas, monospace; }
  h2 { font-size: 14px; margin: 18px 0 6px; color: $blue; }
  p { margin: 6px 0; }
  .note { border-left: 3px solid $blue; padding: 8px 12px;
          background: $soft; border-radius: 6px; color: $ink; }
  .row { display: flex; flex-wrap: wrap; gap: 6px; margin: 8px 0; }
  .tag { font-size: 11px; padding: 2px 8px; border-radius: 999px;
         background: $soft; color: $slate; border: 1px solid $border; }
  .foot { margin-top: 16px; color: $grey; font-size: 11px; }
</style>
</head>
<body>
  <h1>${s.huangyanTitle}</h1>
  <div class="call">BS7H</div>
  <div class="coord">15.1500°N 117.7667°E · Maidenhead ${s.huangyanGrid}</div>

  <h2>${s.huangyanGeoHead}</h2>
  <p>${s.huangyanGeoBody}</p>

  <h2>${s.huangyanHistoryHead}</h2>
  <p>${s.huangyanHistory1}</p>
  <p>${s.huangyanHistory2}</p>

  <h2>${s.huangyanHamHead}</h2>
  <p>${s.huangyanHamBody}</p>

  <div class="note">${s.huangyanLegal}</div>

  <div class="row">
    <span class="tag">${s.huangyanTagReef}</span>
    <span class="tag">${s.huangyanTagDxcc}</span>
    <span class="tag">${s.huangyanTagAxis}</span>
    <span class="tag">BS7H</span>
  </div>

  <div class="foot">${s.huangyanFootNote}</div>
</body>
</html>
''';
}
