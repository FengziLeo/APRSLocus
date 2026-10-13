import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

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
///
/// 这一页自带背景音乐，所以它还多管一件事：**离开时把声音收干净**。WebView
/// 拆掉之后，页面里的 `<audio>` 仍可能继续响（人回到关于页，音乐还跟着 ——
/// 用户报的就是这个），因此退出前先让页面自己按停，退场动画里再把整页腾空。
class StoryPage extends StatefulWidget {
  const StoryPage({super.key});

  @override
  State<StoryPage> createState() => _StoryPageState();
}

class _StoryPageState extends State<StoryPage> with WidgetsBindingObserver {
  /// 包里那一份的正文；`null` = 包里没有（或读不出来）→ 让 WebView 开线上地址。
  String? _html;

  /// 包查完了没有。查之前不建 WebView，否则会先按线上地址发一次请求、紧接着
  /// 又被换成包里那一份（或反过来），白闪一下。
  bool _ready = false;

  /// 内嵌页的控制器（[WebEmbed] 建好后回传）。要在离开这一页之前用它叫停声音。
  WebViewController? _controller;

  /// 已经在退出路上了。连按返回键 / 双击返回按钮时只退一层。
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 最后一道保险：万一这一页不是从 [_exit] 走的（比如上层把整条栈清掉），
    // 也把声音收一遭。此时 WebView 可能已经在拆了，发不出去就算了。
    _silence();
    super.dispose();
  }

  /// 退到后台 / 被切走时，这一页的声音也要停。
  ///
  /// Android 的 WebView **不会**因为应用退到后台就自己暂停 `<audio>`：停在故事
  /// 页上切出去、锁屏，音乐照放。这里只在「不是前台」时按停，页面本身留着
  /// （回来还能接着看）；代价是回来时音乐不会自动续上 —— 页面上那个 BGM 开关
  /// 可以重新点。
  ///
  /// 这一手是**尽力而为**：应用被系统冻住时 JS 跑不动，不过那时系统通常也已
  /// 把声音收了。真正硬的一刀在 [_exit]（退出这一页）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _silence();
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

  /// 退出这一页：先发一句「按停声音」，再退栈。
  ///
  /// 顺序是「先发 JS、再 pop」，而且都不 await：退栈不能为一次 JS 往返卡一下。
  /// 退场动画那 ~300ms 里 WebView 还活着，这一句来得及执行。
  void _exit() {
    if (_leaving) return;
    _leaving = true;
    _silence();
    Navigator.of(context).pop();
    // 整页腾空放在退场动画里做（人已经在往回走了，这时候的空白看不见）：
    // 跨域 iframe 里的兜底播放器从这边选不到它的 <audio>，只有卸载整个文档
    // 才停得住。
    Future<void>.delayed(const Duration(milliseconds: 250), _unload);
  }

  /// 按停页面里的声音（背景音乐 + 任何 `<audio>` / `<video>`）。
  ///
  /// 只为「暂停 + 断开源」：页面本身留着，从后台回来还看得见（虽然音乐不会
  /// 自动续上）。失败一律吞掉 —— 页面还没加载完、控制器已经拆了、JS 报错……
  /// 关不掉声音也不能把人留在这页。
  Future<void> _silence() async {
    final c = _controller;
    if (c == null) return;
    try {
      await c
          .runJavaScript(
            'document.querySelectorAll("audio, video").forEach(function (m) {'
            ' try { m.pause(); m.currentTime = 0;'
            ' m.removeAttribute("src"); m.load(); } catch (e) {} });',
          )
          .timeout(const Duration(milliseconds: 500));
    } catch (_) {}
  }

  /// 把整个文档换成空白页：这一页连同它里面的一切（包括跨域 iframe）都停下。
  Future<void> _unload() async {
    final c = _controller;
    if (c == null) return;
    try {
      await c
          .loadRequest(Uri.parse('about:blank'))
          .timeout(const Duration(milliseconds: 500));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return PopScope(
      // 系统返回键 / 侧滑返回也走 [_exit]：不然声音会跟着人回到关于页
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _exit();
      },
      child: Scaffold(
        backgroundColor: C.bg,
        appBar: MaterialAppBar(
          AppBar(
            backgroundColor: C.surfaceFillStrong,
            elevation: 0,
            leading: IconButton(
              icon: Icon(Icons.arrow_back_rounded, color: C.ink, size: 20),
              onPressed: _exit,
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
                // 拿到控制器，退出前才能叫停这一页自己的背景音乐
                onCreated: (c) => _controller = c,
              )
            : Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.2, color: C.blue),
                ),
              ),
      ),
    );
  }
}
