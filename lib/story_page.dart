import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:url_launcher/url_launcher.dart';

import 'material.dart';
import 'theme.dart';
import 'web_embed.dart';
import 'widgets.dart';

/// 那一页故事（仓库里的 `docs/hero.html` 那一张）。
///
/// 关于页那颗封面彩蛋翻过来之后，落点就是这里 —— 见 `about_page.dart` 的
/// `_activateHeroEgg`。
///
/// **能内嵌的平台（Android / iOS / macOS）就在应用内翻开**：整屏 WebView，直接
/// 开线上那一页（这一页本来就是给一块屏幕看的）；包里带了内置副本就先放副本。
/// 只有没有可用的内嵌后端那三个平台（Windows / Linux / Web，判据见
/// [webEmbedSupported]）才交给系统浏览器 —— 那边连内嵌卡片都渲染不出来，
/// 与其停在「在浏览器打开」的按钮上，不如直接跳过去。
///
/// 这一页的正文（标题、标语、四章、名单）都在 HTML 里，Dart 这侧不复制一份，
/// 免得两边各说各话。
const String kStoryUrl = 'https://aprslocus.theez.top/hero.html';

/// **可选的**包内副本路径。
///
/// 包里带一份的好处：页面正文跟包走，少一次 HTML 请求。**不等于离线可用** ——
/// 它引用的 css / js 仍是相对路径，装载时按 `https://theez.top/` 解析，还是要
/// 联网；真要离线就得把它做成**自包含的单文件 HTML**（样式与脚本内联）。
///
/// 现在 pubspec 的 assets 里还没有 `assets/web/`，所以走的是线上那一页；哪天要
/// 内置，把文件放进 `assets/web/` 并在 pubspec 里声明即可 —— 这个常量不用改。
const String kStoryAsset = 'assets/web/hero.html';

/// 包里带没带这一页（读不出来就是没带；这里不抛异常，返回 `false`）。
Future<bool> storyBundled() async {
  try {
    await rootBundle.load(kStoryAsset);
    return true;
  } catch (_) {
    return false;
  }
}

/// 交给系统浏览器打开线上那一页。
///
/// 只在 [webEmbedSupported] 为假的平台（Windows / Linux / Web）走这里，也是
/// 内嵌页右上角「在浏览器打开」的去处。
///
/// 失败**不做任何提示**：彩蛋里再弹一个错误框，比什么也不发生更让人出戏。
Future<void> openStoryInBrowser() async {
  try {
    await launchUrl(Uri.parse(kStoryUrl), mode: LaunchMode.externalApplication);
  } catch (_) {}
}

/// 彩蛋的落点：能内嵌就在应用内翻开，不能就交给浏览器。
///
/// 调用前请确认 [BuildContext] 还活着（调用方通常在 `Timer` 里等翻面动画）。
Future<void> openStory(BuildContext context) async {
  if (!webEmbedSupported) {
    await openStoryInBrowser();
    return;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const StoryPage()),
  );
}

/// 应用内那一页：整屏内嵌（[WebEmbed]），优先放包里那一份，没有就开线上地址。
class StoryPage extends StatefulWidget {
  const StoryPage({super.key});

  @override
  State<StoryPage> createState() => _StoryPageState();
}

class _StoryPageState extends State<StoryPage> {
  /// 包里那一份的正文；`null` = 包里没有（或读不出来）→ 让 WebView 开线上地址。
  String? _html;

  /// 包查完了没有。查之前不建 WebView，否则会先按线上地址发一次请求、紧接着
  /// 又被换成包里那一份（或反过来），白闪一下。
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    String? html;
    if (await storyBundled()) {
      try {
        html = await rootBundle.loadString(kStoryAsset);
      } catch (_) {
        // 刚查过还在、这会儿又读不出来：当成没内置，线上那一页照开
        html = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _html = html;
      _ready = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: C.bg,
      appBar: MaterialAppBar(
        AppBar(
          backgroundColor: C.surfaceFillStrong,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_rounded, color: C.ink, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_awesome_rounded, size: 16, color: C.blue),
              const SizedBox(width: 6),
              // 品牌名不进 l10n（6 个语言都是这四个字），与封面背面一致
              Text('APRSlocus', style: ts(16, c: C.ink, w: FontWeight.w700)),
            ],
          ),
          centerTitle: true,
          actions: [
            // 想在外面的浏览器里看（去分享、去收藏）时留的口子
            IconButton(
              tooltip: s.openInBrowser,
              icon: Icon(Icons.open_in_new_rounded, color: C.ink, size: 18),
              onPressed: openStoryInBrowser,
            ),
          ],
        ),
      ),
      body: _ready
          ? WebEmbed(
              url: kStoryUrl,
              html: _html,
              height: double.infinity,
              radius: 0,
            )
          : Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2, color: C.blue),
              ),
            ),
    );
  }
}
