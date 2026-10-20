import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'l10n/app_localizations.dart';
import 'material.dart';
import 'theme.dart';
import 'web_embed.dart';
import 'widgets.dart';

/// ─── 手册 ───
///
/// 手册的正文在官网（`docs/manual*/`，由 `tool/gen_manual_pages.py` 生成），
/// 这里**不复制一份**：Dart 里再写一遍等于第二份真相，改了一边另一边就开始说谎。
///
/// 三条语言的地址各自独立（站点就是这么发布的），日语 / 西班牙语 / 印尼语
/// 没有对应目录，落到英文那套 —— 与公告的做法一致（见 `notice.dart`）。
const String kManualBase = 'https://aprslocus.theez.top';

/// 语言码 → 手册地址。认不出的一律英文。
String manualUrlFor(String lang) {
  switch (lang) {
    case 'zh':
      return '$kManualBase/manual/index.html';
    case 'zh_TW':
      return '$kManualBase/zh-TW/manual/index.html';
    default:
      return '$kManualBase/en/manual/index.html';
  }
}

/// 当前界面的语言码（`zh` / `zh_TW` / `en` …）。
String manualLangOf(BuildContext context) =>
    Localizations.localeOf(context).toString();

/// 能内嵌就在应用内翻开，不能就交给系统浏览器（Windows / Linux / Web，
/// 判据见 [webEmbedSupported] 与故事页同一套）。
Future<void> openManual(BuildContext context) async {
  final url = manualUrlFor(manualLangOf(context));
  if (!webEmbedSupported) {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
    return;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const ManualPage()),
  );
}

/// 应用内那一页：整屏内嵌手册。
class ManualPage extends StatelessWidget {
  const ManualPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final url = manualUrlFor(manualLangOf(context));
    return Scaffold(
      backgroundColor: C.bg,
      appBar: MaterialAppBar(
        AppBar(
          backgroundColor: C.surfaceFillStrong,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_rounded, color: C.ink, size: 20),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book_rounded, size: 16, color: C.blue),
              const SizedBox(width: 6),
              Text(s.manualTitle, style: ts(16, c: C.ink, w: FontWeight.w700)),
            ],
          ),
          centerTitle: true,
          actions: [
            // 想在外面浏览器里看（去收藏、去分享）时留的口子
            IconButton(
              tooltip: s.openInBrowser,
              icon: Icon(Icons.open_in_new_rounded, color: C.ink, size: 18),
              onPressed: () => launchUrl(
                Uri.parse(url),
                mode: LaunchMode.externalApplication,
              ),
            ),
          ],
        ),
      ),
      body: WebEmbed(
        url: url,
        height: double.infinity,
        radius: 0,
      ),
    );
  }
}
