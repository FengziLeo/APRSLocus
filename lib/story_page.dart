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
/// `_activateHeroEgg`。这一页**只做一件事**：有内置就在应用内打开
/// （[StoryPage]），没有就交给系统浏览器（[openStoryInBrowser]）。
///
/// ## 为什么按「有没有内置」分两条路
///
/// 应用内那一层是 WebView（Android / iOS / macOS，判据见 [webEmbedSupported]），
/// 它**没有地址栏、没有返回键、没有分享**：往里塞一个线上地址，页面里的外链、
/// `fetch`、双指缩放就都变成「应用自己的事」了，而这一页本来是一个**网站**。
/// 包里带一份的时候它是自包含的一个文件，怎么点都不会走出去；没带的时候，
/// 交给浏览器才是最诚实的那条路 —— 那本来就是它的处境。
///
/// 这一页的正文（标题、标语、四章、名单）都在 HTML 里，Dart 这侧不复制一份，
/// 免得两边各说各话。
const String kStoryUrl = 'https://aprslocus.theez.top/hero.html';

/// 包内副本的路径。
///
/// **现在包里没有这一份**（pubspec.yaml 的 assets 里没有 `assets/web/`），
/// 所以 [openStory] 走的是浏览器那条路。哪天真要搬进包里，得把它连同用到的
/// css / js / 字体做成**自包含的单文件 HTML**（`loadHtmlString` 解析不到相对
/// 路径的资源，图片与脚本都得内联或走线上绝对地址），放进 `assets/web/`、
/// 在 pubspec 里声明 —— 这个常量不用改。
const String kStoryAsset = 'assets/web/hero.html';

/// 包里带没带这一页。
///
/// 读不出来就是没带：这里**不抛异常**，也就不必在调用处再决定「读失败怎么办」。
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
/// 既是 [openStory] 没有内置时的那条路，也是本页读不出资源时的兜底。
/// 失败**不做任何提示**：彩蛋里再弹一个错误框，比什么也不发生更让人出戏。
Future<void> openStoryInBrowser() async {
  try {
    await launchUrl(Uri.parse(kStoryUrl), mode: LaunchMode.externalApplication);
  } catch (_) {}
}

/// 彩蛋的落点：有内置就在应用内打开，没有就交给浏览器。
///
/// 调用前请确认 [BuildContext] 还活着（调用方通常在 `Timer` 里等翻面动画）。
Future<void> openStory(BuildContext context) async {
  if (webEmbedSupported && await storyBundled()) {
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const StoryPage()),
    );
    return;
  }
  await openStoryInBrowser();
}

/// 应用内的那一页：整屏内嵌，装的是包里的自包含副本。
class StoryPage extends StatefulWidget {
  const StoryPage({super.key});

  @override
  State<StoryPage> createState() => _StoryPageState();
}

class _StoryPageState extends State<StoryPage> {
  /// 包里那一页的正文。读完之前不建 WebView：**首帧空白比转圈更像坏了**。
  String? _html;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final html = await rootBundle.loadString(kStoryAsset);
      if (mounted) setState(() => _html = html);
    } catch (_) {
      // 能进到这一页，说明 [storyBundled] 刚查过、资源是在的。走到这里只剩
      // 「打包漏了 / 读坏了」这类意外：不留一张空白页 —— 交给浏览器，再退回关于页。
      if (!mounted) return;
      await openStoryInBrowser();
      if (!mounted) return;
      Navigator.of(context).maybePop();
    }
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
            // 这一页本来就是给浏览器写的，留个口子去外面看
            IconButton(
              tooltip: s.openInBrowser,
              icon: Icon(Icons.open_in_new_rounded, color: C.ink, size: 18),
              onPressed: openStoryInBrowser,
            ),
          ],
        ),
      ),
      body: _html == null
          ? Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2, color: C.blue),
              ),
            )
          : WebEmbed(
              url: kStoryUrl,
              html: _html,
              height: double.infinity,
              radius: 0,
            ),
    );
  }
}
