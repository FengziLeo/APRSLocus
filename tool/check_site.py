# -*- coding: utf-8 -*-
"""推送前终检：结构 / 内容一致性 / SEO / 无障碍 / 主题 / CSS·JS 完整性。
跑法：python3 tool/check_site.py （仓库根目录）退出码非 0 即不过。
"""
import io
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from html.parser import HTMLParser

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_embedded_js import mask as _mask_js  # noqa: E402  状态机掩码，比正则可靠
VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input',
        'link', 'meta', 'param', 'source', 'track', 'wbr'}
FAILS = []


class P(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.err = []

    def handle_starttag(self, t, a):
        if t not in VOID:
            self.stack.append((t, self.getpos()))

    def handle_endtag(self, t):
        if t in VOID:
            return
        if not self.stack:
            self.err.append('extra </%s> %s' % (t, self.getpos()))
            return
        if self.stack[-1][0] != t:
            self.err.append('mismatch </%s> %s vs <%s> %s'
                            % (t, self.getpos(), self.stack[-1][0], self.stack[-1][1]))
            for i in range(len(self.stack) - 1, -1, -1):
                if self.stack[i][0] == t:
                    del self.stack[i:]
                    return
        else:
            self.stack.pop()


def chk(name, cond, extra=''):
    if not cond:
        FAILS.append(name)
    print(('  OK  ' if cond else '  FAIL') + ' ' + name + ((' | ' + str(extra)) if extra else ''))


def read(rel):
    return io.open(os.path.join(ROOT, rel), encoding='utf-8').read()


def _cl_vers():
    """生成器里配的全部更新日志版本号（tool/sync_site_content.py 的 CL）。

    与 `_newest_ver()` 同一类：从**源**取，而不是把版本号抄进检查器
    （抄进去的话每发一版都要改检查器，忘了改就是「检查失败但内容是对的」）。
    """
    try:
        # ⚠ 缩进别写死：CL 的条目实际缩进是 **8 个空格**，第一版按 4 写，
        #   结果一个都没匹配到 → `missing` 永远为空 → 判据形同虚设
        #   （回归样本当场验出来的：把版本号改错也报绿）。
        return re.findall(r"(?m)^\s*'ver': '([^']+)'",
                          read('tool/sync_site_content.py'))
    except Exception:
        return []


def _newest_ver():
    """CHANGELOG.md 里最新的版本号，形如 `v1.6.155`。

    给「首页有没有提到最新版本」用：写死版本号的那一版每隔几个版本就得改一次，
    而忘了改的表现是**检查失败但内容其实是对的** —— 反过来更糟：发版后忘了跑
    同步脚本时，写死的版本号仍然「通过」，首页却停在旧版本上。
    """
    m = re.search(r'(?m)^## \[([0-9]+\.[0-9]+\.[0-9]+)\]',
                  read('CHANGELOG.md'))
    return 'v' + m.group(1) if m else ''


def main():
    print('[home x3]')
    for f in ['docs/index.html', 'docs/zh-TW/index.html', 'docs/en/index.html']:
        s = read(f)
        p = P()
        p.feed(s)
        print(' ' + f)
        chk('html structure', not p.err and not p.stack, p.err[:1])
        # 首页的卡片与更新日志 = **遗留手写条目 + tool/sync_site_content.py 生成的块**。
        #
        # 这里刻意**不写死条数**：写死的话每发一版都要改检查器，而忘了改的表现是
        # 「检查失败但内容其实是对的」—— 已经因此误报过两次（v1.6.155、v1.6.156）。
        # 改成两条**自洽**判据，既不用维护数字、又保留真正要守的不变量：
        #   * 三个语言页的条数必须一致（不一致就是某页漏了）；
        #   * 每页至少包含「生成的那些条」（见 tool/sync_site_content.py 的 CL）。
        # 只判「有多少条」是**抓不到真问题**的：页面里还留着几条手写的老条目，
        # 少一条生成的也照样 ≥ 阈值（回归样本当场验出来的）。
        # 所以要**逐条点名**：生成器配置的每个版本都必须在页面上出现。
        vers = _cl_vers()
        missing = [v for v in vers
                   if '<span class="cl-tag">%s</span>' % v not in s]
        # 功能条目计数用**前缀**匹配（`class="feat reveal`）：将来哪天某一行多挂了
        # 一个类名（`feat reveal is-new`），整串匹配就会把它数漏 —— 少数一行、看着
        # 还全绿，正是这类判据最坑的地方。
        chk('feat rows/cl present (%d rows, %d/%d vers)' %
            (s.count('<article class="feat reveal'),
             len(vers) - len(missing), len(vers)),
            s.count('<article class="feat reveal') >= 10 and not missing)
        # 「最新版本出现在首页」不写死版本号：从 CHANGELOG 现取。
        # 这条同时盯着「发版后忘跑 sync_site_content.py」—— 那时首页还停在旧版本。
        chk('latest release in cl', _newest_ver() in s)
        chk('a11y set', all(x in s for x in
                            ['skip-link', 'heroCanvas" aria-hidden="true"',
                             'aria-expanded="false"', 'id="themeToggle"']))
        chk('theme script + canonical',
            "localStorage.getItem('theme')" in s and 'rel="canonical"' in s)
        chk('faq entry link', 'href="faq.html"' in s)

    print('[home parity x3]')
    # 三语首页必须**同构**：section 序列与导航项逐项一致。
    #
    # 背景：中文页曾经独自多出「2.0 界面」section（连同导航里的「界面」），
    # 繁体 / 英文页没有；而当时的判据只看卡片数与更新日志，两页少一整段也照样全绿。
    # 这是「检查器只数个数、不点名」的第三次翻车（前两次见上面卡片与设置页），
    # 所以这里换成**逐项相等**并且两个方向都报：
    #   * zh-TW / en 缺的（别人有的你没有）
    #   * zh-TW / en 多的（你有别人没有）
    # 只比较 zh 与另两语，**不以某一页为“正确”**——谁多谁少都是漂移。
    NAV = re.compile(r'<nav class="nav-links" id="navLinks">(.*?)</nav>', re.S)
    SEC = re.compile(r'<section[^>]*\bid="([^"]+)"')
    home = {}
    for lang, f in (('zh', 'docs/index.html'),
                    ('zh-TW', 'docs/zh-TW/index.html'),
                    ('en', 'docs/en/index.html')):
        s = read(f)
        m = NAV.search(s)
        # 语言切换组的相对路径天然各页不同（./ 与 ../ 混用），不参与比较；
        # 主题按钮没有 href，也进不来。
        inner = m.group(1).split('<span class="lang-switch-group">')[0] if m else ''
        nav = [h.replace('../', '') for h in re.findall(r'href="([^"]+)"', inner)]
        home[lang] = (SEC.findall(s), nav)
    ref_sec, ref_nav = home['zh']
    for lang in ('zh-TW', 'en'):
        sec, nav = home[lang]
        chk('首页 section 同构 %s vs zh' % lang, sec == ref_sec,
            '缺=%s 多=%s' % ([x for x in ref_sec if x not in sec],
                            [x for x in sec if x not in ref_sec]))
        chk('首页导航同构 %s vs zh' % lang, nav == ref_nav,
            '缺=%s 多=%s' % ([x for x in ref_nav if x not in nav],
                            [x for x in nav if x not in ref_nav]))

    print('[home motion]')
    # 首页动效层（docs/css/motion.css + docs/js/motion.js）：同层的一排 .reveal
    # 依次涌上来、hover 抬升、功能卡的单一强调色。
    #
    # 这一层是**首页专属**：只挂三语 index.html，子页一行都不碰（文档页要稳）。
    # 所以既查"三语都在"，也查"别的页都没有" —— 只查一半的话，哪天有人把它拷进
    # 帮助中心，子页的 .cards 会跟着一起晃，而判据照样全绿。
    homes = ['docs/index.html', 'docs/zh-TW/index.html', 'docs/en/index.html']
    motion_css = read('docs/css/motion.css')
    motion_js = read('docs/js/motion.js')
    # 下面的正则一律拿**去掉注释**的副本去跑：motion.css 的注释里正好写着
    # “`.card:hover{transform:…}` 被压死”这句说明，拿原文匹配会把说明本身当成
    # 违规（当场报了一次假 FAIL）。注释不是代码，不该进判据。
    motion_plain = re.sub(r'/\*.*?\*/', '', motion_css, flags=re.S)
    mj, _mjerr = _mask_js(motion_js)
    chk('动效层语法自洽（CSS 括号 / JS 括号）',
        motion_css.count('{') == motion_css.count('}') and
        mj.count('{') == mj.count('}') and mj.count('(') == mj.count(')') and
        all(x in motion_js for x in ('data-fx', '--fx-d', 'data-fx1', 'getBoundingClientRect')))
    chk('动效层只挂首页（三语有、别的页没有）',
        all('motion.css' in read(f) and 'motion.js' in read(f) for f in homes) and
        all('motion.css' not in read(f) and 'motion.js' not in read(f)
            for f in ['docs/faq.html', 'docs/zh-TW/faq.html', 'docs/en/faq.html',
                      'docs/manual/start.html', 'docs/zh-TW/manual/start.html',
                      'docs/en/manual/start.html']))
    chk('动效层接线三语一致（相对路径 + 同一个 ?v=）',
        all(read(f).count('motion.css?v=1') == 1 and read(f).count('motion.js?v=1') == 1
            for f in homes) and
        len(set(re.findall(r'motion\.css\?v=(\d+)', read(f))[0] for f in homes)) == 1 and
        len(set(re.findall(r'motion\.js\?v=(\d+)', read(f))[0] for f in homes)) == 1)
    # hover 抬升必须走 translate 而不是 transform：style.css 里
    # `.reveal.in{transform:none}` 排在 `.card:hover{transform:…}` 之后、特异性又相同，
    # 拿 transform 做 hover 会被它一直压死（改了看不出变化，极易当成"没生效"再改一遍）。
    chk('动效层 hover 抬升不与 .reveal.in 打架（走 translate）',
        '[data-fx] > .cl-version:hover { translate:' in motion_css and
        # 只盯 :hover 紧跟 { 的那条规则本体（`…:hover::before{transform:…}` 是扫光，合规）
        re.search(r':hover\s*\{[^}]*transform:', motion_plain) is None)
    chk('动效层：延迟只写在 .in 态（hover 才不用跟着等）',
        re.search(r'\[data-fx\] > \.reveal\.in \{[^}]*transition-delay: var\(--fx-d',
                  motion_plain) is not None)
    # 功能清单是**分组序号列表**，不是卡片（docs/css/features.css）：18 行 + 4 个组标题。
    #
    # 判据分三层，缺一层就会漏掉真问题：
    #   * 只查"还有没有卡片"—— 把整段删了也算通过；
    #   * 只查行数 —— 分组乱序、编号重复都看不见；
    #   * 只查中文页 —— 另两页少一组很正常（这正是当年"中文页多出一个 section"的翻车）。
    # 所以三语逐项比对（编号序列 / 组数 / 每行有没有正文与标签），再单独点名编号连续。
    feat = {}
    for f in homes:
        s = read(f)
        seg = s[s.index('id="features"'):s.index('id="platforms"')]
        feat[f] = (tuple(re.findall(r'<span class="feat-no">(\d+)</span>', seg)),
                   len(re.findall(r'<p class="feat-group">', seg)),
                   len(re.findall(r'<ul class="feat-tags">', seg)),
                   len(re.findall(r'<div class="feat-main">', seg)),
                   '<article class="card' in seg)
    ref = feat['docs/index.html']
    chk('功能清单三语同构（编号 / 组数 / 每行正文与标签）',
        len(set(feat.values())) == 1, feat)
    chk('功能清单 18 行 4 组、编号 01~18 连续、没有卡片写法',
        ref[0] == tuple('%02d' % i for i in range(1, len(ref[0]) + 1)) and
        len(ref[0]) == 18 and ref[1] == 4 and ref[2] == 18 and ref[3] == 18 and
        not ref[4])
    # 序号行的入场：只上浮。缩放/模糊是"一堆小方块在弹"的观感 —— 之前正是这个
    # 被反馈过，所以把"只上浮"钉成判据，免得哪天顺手加个 scale 又回去。
    row_rule = re.search(r'\[data-fx\] > \.feat \{([^}]*)\}', motion_plain)
    chk('序号行入场只上浮（不缩放 / 不模糊）',
        row_rule is not None and 'translateY(14px)' in row_rule.group(1) and
        'scale' not in row_rule.group(1) and 'blur' not in row_rule.group(1))
    # 样式层是首页专属：只挂三语 index.html，子页一行都不碰（文档页要稳）。
    feat_css = read('docs/css/features.css')
    chk('功能清单样式只挂首页（三语有、子页没有、同一个 ?v=）',
        all(read(f).count('features.css?v=') == 1 for f in homes) and
        len(set(re.findall(r'features\.css\?v=(\d+)', read(f))[0] for f in homes)) == 1 and
        all('features.css' not in read(f)
            for f in ['docs/faq.html', 'docs/zh-TW/faq.html', 'docs/en/faq.html',
                      'docs/manual/start.html', 'docs/zh-TW/manual/start.html',
                      'docs/en/manual/start.html', 'docs/guide.html', 'docs/promo.html']))
    # 深浅两套不再各写一遍：这一层把颜色全指到共享 token，主题切换自己就跟着走。
    # 所以判据也改了 —— 不再数 [data-theme="dark"] 的条数，改成「一个颜色字面量都没有」。
    chk('功能清单 CSS 自洽（括号 / 六个部件 / 全走 token / 自己不写卡片样式）',
        feat_css.count('{') == feat_css.count('}') and
        all(x in feat_css for x in ('.feat-list', '.feat-group', '.feat-no', '.feat-ico',
                                    '.feat-main', '.feat-tags')) and
        '--feat-rule' in feat_css and
        not re.search(r'#[0-9a-fA-F]{3,8}\b|rgba?\(|(?<![\w-])(?:white|black|silver)(?![\w-])', feat_css) and
        not re.search(r'^\s*\.card\b', feat_css, re.M))

    print('[home nav]')
    # 首页导航：13 个链接横排一行 → 收成一个「更多」面板（docs/css/nav.css + nav.js）。
    #
    # 判据分两层，缺一层就会漏掉真问题：
    #   * 只看"外面剩几个" —— 把链接直接删掉也算通过（面板空了谁知道）；
    #   * 只看"旧的入口都在" —— 把 13 个又摆回外面也通过（旧样子正好全符合）。
    # 所以两边都点：外面 ≤5 个顶层链接、面板 ≥8 条，且旧的 13 个 href 一个不少。
    NAV_INNER = re.compile(r'<nav class="nav-links" id="navLinks">(.*?)</nav>', re.S)
    KEEP = ['#announce', '#features', '#ui2', '#platforms', '#changelog',
            '#getting-started', '#faq', '#community', '#friends',
            'manual/index.html', 'guide.html', 'card.html', 'promo.html']
    for f in homes:
        s = read(f)
        m = NAV_INNER.search(s)
        inner = m.group(1) if m else ''
        pm = re.search(r'<div class="nav-more" id="navMore">.*?<div class="nav-more-list" id="navMoreList">(.*?)</div>\s*</div>',
                       inner, re.S)
        items = re.findall(r'<a\b[^>]*href="([^"]+)"', pm.group(1)) if pm else []
        # 把面板整块抽掉再数外面剩了几个 —— 面板在 DOM 里排在 theme 按钮之前，
        # 不抽掉的话它会跟着一起被数进"顶层"（当时测出 14 个，其实外面只有 5 个）。
        outer = inner[:pm.start()] + inner[pm.end():] if pm else inner
        outer = outer.split('<button class="theme-toggle"')[0]
        top = re.findall(r'<a\b[^>]*href="([^"]+)"', outer)
        got = set(h.replace('../', '') for h in top + items)
        chk('%s : 导航不再堆一排（顶层 %d 个 / 面板 %d 条）' % (f, len(top), len(items)),
            len(top) <= 5 and len(items) >= 8 and all(k in got for k in KEEP) and
            'aria-haspopup="true"' in s and 'aria-controls="navMoreList"' in s and
            'id="navMoreBtn"' in s,
            '缺=%s' % [k for k in KEEP if k not in got])
    nav_css = read('docs/css/nav.css')
    nav_js = read('docs/js/nav.js')
    nav_plain = re.sub(r'/\*.*?\*/', '', nav_css, flags=re.S)
    nj, _njerr = _mask_js(nav_js)
    chk('导航层语法自洽 + 窄屏把面板摊平',
        nav_css.count('{') == nav_css.count('}') and
        nj.count('{') == nj.count('}') and nj.count('(') == nj.count(')') and
        '.nav-more { display: contents; }' in nav_css and
        '.nav-more-btn { display: none; }' in nav_css)
    chk('导航层只挂首页（三语有、别的页没有，且同一个 ?v=）',
        all(len(re.findall(r'nav\.css\?v=\d+', read(f))) == 1 and
            len(re.findall(r'nav\.js\?v=\d+', read(f))) == 1 for f in homes) and
        len(set(re.findall(r'nav\.css\?v=(\d+)', read(f))[0] for f in homes)) == 1 and
        len(set(re.findall(r'nav\.js\?v=(\d+)', read(f))[0] for f in homes)) == 1 and
        all('nav.css' not in read(f) and 'nav.js' not in read(f)
            for f in ['docs/faq.html', 'docs/zh-TW/faq.html', 'docs/en/faq.html',
                      'docs/manual/start.html', 'docs/zh-TW/manual/start.html',
                      'docs/en/manual/start.html']))
    # 面板收起来时 scrollspy 的高亮看不见了 —— 得过继到「更多」按钮上，
    # 否则滚到「平台 / 更新 / 问答」时导航看上去像没在跟着走。
    chk('导航高亮过继给「更多」按钮',
        'MutationObserver' in nav_js and 'classList.toggle("active"' in nav_js and
        '.nav-more-btn.active::after' in nav_plain)

    print('[hero 3d]')
    # 首页 Hero：左侧 3D 星球（原生 WebGL 点云）+ 右侧累计报文遥测。
    #
    # 数值只该有一个源头：docs/stats.json。页面里的静态回退值（无 JS 或
    # stats.json 抓取失败时显示的那个数）必须与它一致 —— 只判「页面上有数字」
    # 是抓不到真问题的：改了 stats.json 忘了改页面，表现就是三语首页各显示
    # 一个不同的累计量，而旧判据全绿。
    try:
        stats = json.loads(read('docs/stats.json'))
        chk('docs/stats.json 可解析 + 字段齐',
            all(k in stats for k in ('packets', 'packetsPerMinute', 'updated', 'updatedIso')))
    except Exception as e:
        stats = None
        chk('docs/stats.json 可解析', False, e)
    if stats:
        pk = '{:,}'.format(stats['packets'])
        vers = []
        for f in ('docs/index.html', 'docs/zh-TW/index.html', 'docs/en/index.html'):
            s = read(f)
            up = '' if f == 'docs/index.html' else '../'
            chk('%s : hero 星球层就位、旧面板已撤' % f,
                'id="planetCanvas"' in s and 'class="planet-fallback"' in s
                and 'id="heroTelemetry"' in s and 'class="hero-stat"' in s
                and 'hero-phone' not in s and 'hero-stage' not in s
                and 'data-stale-title="' in s)
            # 星球直接长在 hero 上、不在面板里：画布必须排在 .hero-inner 前面
            chk('%s : 星球画布在 hero 层（非面板）' % f,
                s.index('id="planetCanvas"') < s.index('class="hero-inner"')
                and 'class="hero-grid"' in s)
            chk('%s : 读数静态值 = stats.json' % f,
                'data-packets="%d"' % stats['packets'] in s
                and 'data-rate="%d"' % stats['packetsPerMinute'] in s   # 速率还在用：数字按它往上跳，只是不再写出来
                and 'id="tlPackets">%s<' % pk in s)
            # 只报数字：上限/时间戳/进度条这类"像上传面板"的元信息都不要再出现；
            # 每分钟速率那行小注与 LIVE 心跳点也一并撤了（读写数只要一个数）。
            chk('%s : 只留那个数字（无速率小注 / 无心跳点 / 无时间戳）' % f,
                not any(x in s for x in ('tlStamp', 'tlInc', 'tlBar', 'tlNext', 'tl-bar',
                                         'tlRateNum', 'hs-live', 'hs-foot')))
            # 读数竖排三级：标签（这是什么）→ 数字 → 一行小注。顺序是这里唯一的
            # 信息层级 —— 标签写在数字之后，就又变成"数字后面跟一行小字注释"了。
            lb = s.find('class="hs-label"')
            pk_i = s.find('id="tlPackets"')
            chk('%s : 读数只有标签 + 数字（标签在数字之前）' % f,
                lb > 0 and pk_i > lb
                and s.count('class="hs-label"') == 1 and s.count('id="tlPackets"') == 1)
            # 首屏只摆那个数字：读数必须在 .hero-copy-next（说明 + 下载）之前，
            # 且自己独占 .hero-copy。两块一旦回到同一个盒子里，滚动退场那套淡出
            # 就会把折线之下的说明连坐成半透明（滚过 0.8 屏只剩 12%）。
            st = s.find('id="heroTelemetry"')
            nxt = s.find('class="hero-copy-next"')
            chk('%s : 数字独占首屏，说明与下载另起一块跟在它后面' % f,
                0 < st < nxt and s.count('class="hero-copy"') == 1
                and s.count('class="hero-copy-next"') == 1)
            # 标签要写清这个数字是**谁的、是什么**：首屏只有数字 + 这行小字，
            # 少了品牌名就只剩一个来路不明的计数器。
            chk('%s : 读数标签带品牌名' % f,
                re.search(r'class="hs-label">[^<]*APRSlocus', s) is not None)
            # 说明（邀请那句）要有，而且排在数字**之后**、和下载一样在折线之下，
            # 靠 .reveal 滚上来才淡出。只判「有 hero-invite」抓不到顺序写反。
            inv = s.find('class="hero-invite"')
            chk('%s : 说明排在数字之后、滚上来才淡出' % f,
                inv > st > 0 and nxt < inv and 'class="hero-intro reveal"' in s
                and 'class="hi-mark"' in s)
            # 下载那块排在说明之后，同样挂 .reveal：先看数字 → 再读说明 → 最后动手
            cta = s.find('class="hero-cta reveal"')
            chk('%s : 下载排在说明之后、滚下去才弹出' % f, cta > inv > 0)
            vers.append(re.findall(r'hero-3d\.css\?v=(\d+)', s) + re.findall(r'planet-3d\.js\?v=(\d+)', s))
            chk('%s : hero-3d 资源接线' % f,
                '%scss/hero-3d.css?v=' % up in s
                and '%sjs/planet-3d.js?v=' % up in s
                and 'data-stats="%sstats.json"' % up in s
                and 'data-updated="%s"' % stats['updatedIso'] in s)
        # 三语首页必须链接同一个版本号；线上已缓存过旧值，所以要求 >= 2
        flat = sorted({v for pair in vers for v in pair})
        chk('hero-3d 资源版本三语一致且 >=2', len(flat) == 1 and int(flat[0]) >= 2, flat)
    # 降级链路：没有 WebGL 时不能把 hero 那块留成空白。
    # 只看「页面里有 canvas」是不够的，真会坏的是脚本早期 return 之后什么都
    # 没画，所以要求 CSS 有 .no-3d 分支、脚本有失败回落。
    hero_css = read('docs/css/hero-3d.css')
    hero_js = read('docs/js/planet-3d.js')
    chk('hero-3d.css 大括号平衡', hero_css.count('{') == hero_css.count('}'))
    chk('hero 降级链路 (no-3d / no-webgl)',
        '.hero.no-3d .planet-canvas' in hero_css and '.hero.no-3d .planet-fallback' in hero_css
        and 'no-webgl' in hero_js and 'classList.add("no-3d")' in hero_js)
    # 透明画布是"没有面板感"的根：底色一写回去就又变成一块方框了
    chk('hero 画布保持透明 (alpha:true + clearColor alpha 0)',
        'alpha: true' in hero_js and 'clearColor(0, 0, 0, 0)' in hero_js)
    # 动感：星面三层浪 + 小流星撞进来荡开冲击波。这里守的是"还在不在"，
    # 而 pow(负数, 2.0) 在 GLSL 里是未定义 —— 那行一旦被写回去，冲击环会整片
    # 变成 NaN（点凭空消失），所以顺手把正确写法也钉住。
    chk('hero 星球动感：海浪 + 粒子对撞',
        all(x in hero_js for x in ('uWave', 'uImpDir0', 'uImpAge2', 'IMP_SLOTS', 'IMP_AGE',
                                   'buildImpacts', 'stepImpacts', 'pickImpactDir'))
        and 'exp(-qa * qa)' in hero_js and 'pow((distance(' not in hero_js
        and 'uWave' in hero_js and '.hero-stat.stale .tl-value' in hero_css)
    # 撞击的收尾必须"化开"而不是被闸门切断：环要减速扩张（1-e^-t）、要随时间变宽、
    # 亮度用 smoothstep 起手 + 长尾衰减，且流星在到达前先淡掉（命中是一次交接）。
    # 上一版是 step(1.20, age) 一刀切 + 匀速环 —— 用户看到的就是"啪"地断掉。
    chk('hero 撞击收尾是化开的（减速环 / 变宽 / 流星淡出交接）',
        '1.0 - exp(-a0 * 1.5)' in hero_js and '4.4 - 1.9 * min(a0, 1.2)' in hero_js
        and 'smoothstep(0.0, 0.06, a0)' in hero_js and '1.0 - smoothstep(0.6, 1.9, a0)' in hero_js
        and 'smooth01(0.0, 0.14, f)' in hero_js and '1.0 - smooth01(0.70, 1.0, f)' in hero_js
        and '(1.0 - step(1.20' not in hero_js)
    # 动画时钟 + 读数之后的滑行：随时间演的一切都吃 animT（暂停回来不跳），
    # 滚动量在 JS 里缓动过（每帧朝目标挪一档），CSS 那边不写 transition。
    chk('hero 滚动丝滑（JS 缓动 + animT 时钟）',
        all(x in hero_js for x in ('animT', 'SCROLL_EASE', 'glide', 'scrollTarget', 'writeScroll'))
        and all(x in hero_css + hero_js for x in ('--hero-3d-copy-scale', '--hero-3d-next'))
        and all(x in hero_css for x in ('--hero-3d-copy-scale', '--hero-3d-next', 'will-change: transform')))
    # 着色器与脚本之间的名字必须对得上。名字打错的话 getUniformLocation 返回
    # null，uniform 调用静默失效 —— 浏览器不报任何错，只是那个效果凭空不见，
    # 是最难查的一类问题（这类错误只有真跑起来、且真的盯着看才发现）。
    def shader_src(tag):
        i = hero_js.index('var %s = [' % tag)
        j = hero_js.index('].join("\\n")', i)
        out = []
        for ln in hero_js[i:j].split('\n'):
            m = re.match(r'\s*"((?:[^"\\\\]|\\\\.)*)"', ln)
            if m:
                out.append(m.group(1))
        return '\n'.join(out)

    def shader_uniforms(src):
        got = set()
        for m in re.finditer(r'\buniform\s+\w+\s+([^;]+);', src):
            for n in m.group(1).split(','):
                got.add(n.strip())
        return got

    def lookup_names(var):
        i = hero_js.index('var %s = {};' % var)
        j = hero_js.index('].forEach(function (k)', i)
        return set(re.findall(r'"([A-Za-z_]\w*)"', hero_js[i:j]))

    for tag in ('VS', 'FS', 'WVS', 'WFS'):
        src = shader_src(tag)
        chk('hero 着色器 %s 括号配平' % tag,
            src.count('(') == src.count(')') and src.count('{') == src.count('}'))
    for lst, vert, frag in (('U', 'VS', 'FS'), ('WU', 'WVS', 'WFS')):
        names = lookup_names(lst)
        declared = shader_uniforms(shader_src(vert)) | shader_uniforms(shader_src(frag))
        chk('hero 着色器 uniform 与 %s 名单一致' % lst,
            not (names - declared) and not (shader_uniforms(shader_src(vert)) - names),
            'extra=%s missing=%s' % (sorted(names - declared),
                                     sorted(shader_uniforms(shader_src(vert)) - names)))
    chk('hero 读数跳动三件 (bump / 闪点 / 无旧控件)',
        '.tl-value.bump' in hero_css
        and all(x in hero_js for x in ('tlPackets', 'hooks.flash'))
        and not any(x in hero_js for x in ('tlBar', 'tlNext', 'tlStamp')))
    # 入场：一进页面点云要「聚成球」（uGather 把点从散开的一层拉回球面），
    # 滚动：往下拉时星球与文案要慢慢退开。两件事都横跨 JS 与 CSS —— 一边写成
    # 变量、另一边读成 transform，缺一边就是「代码在、效果没了」。
    chk('hero 入场聚成球 (uGather) + 滚动退场接线',
        all(x in hero_js for x in ('uGather', 'GATHER_MS', 'easeOutCubic'))
        and all(x in hero_css for x in ('--hero-3d-y', '--hero-3d-fade', '--hero-3d-copy-fade'))
        and all(x in hero_js for x in ('--hero-3d-y', '--hero-3d-copy-fade', 'applyScroll'))
        and 'heroCueDrop' in hero_css)
    # 星球的模样照参考设计（NASA-Punk Observatory）：点云 + 线框球 + 环带。
    # 这三样是这一版星球的骨架，回退某一样就不是那颗星了。
    # 一屏只有一支强调色：星球是单族蓝，台站 / 卫星靠"亮度分档"（uStn 按主题
    # 给）区分，而不是换色相。上一版是琥珀 / 橙 + 青紫渐变，摆在一起就是花的。
    chk('hero 只用一族蓝（无第二色相）',
        'amber' not in hero_js and 'orange' not in hero_js
        and all(x not in hero_css for x in ('#a855f7', '#7c3aed', '#22d3ee', '#f59e0b', '#22c55e'))
        and 'vec3 uStn' in hero_js and 'stn: [' in hero_js)
    # 卫星：几颗带尾迹的小亮点快速划过。位置每帧现算（buildSats），不是一圈
    # 静止的轨道点 —— 上一版那圈点已经撤掉，留着会和对不上的轨道叠成两层。
    # 尾迹分两截（亮点串 + 更淡的轨迹弧）。点数算式必须与写入的循环对齐：
    # tail 循环是"含头"的 j <= tail（+1 个点），wake 循环是 j < wake（正好 wake 个），
    # 两个 off-by-one 都会让 tail/wake 数组越界写（静默丢点）。
    chk('hero 卫星：一组带尾迹 + 轨迹弧',
        'var SATS = [' in hero_js and 'function buildSats' in hero_js
        and 'SAT_STEP' in hero_js and 'satBuf' in hero_js and 'ORBIT_SPIN' not in hero_js
        and 'j <= s2.tail' in hero_js and 'j < s2.wake' in hero_js
        and 'SATS[si].tail + SATS[si].wake' in hero_js and 's2.arc' in hero_js
        and hero_js.count('tail: ') == hero_js.count('wake: ') >= 6)
    chk('hero 星球：线框球 + 纬向色带 + 开普勒环',
        'function buildWire' in hero_js and 'gl.LINES' in hero_js
        and 'uSpinT' in hero_js
        and 'noise3(x * 0.5, y * 3.0, z * 0.5)' in hero_js
        and 'Math.pow(RING_IN / rad, 1.5)' in hero_js)

    print('[help center x3]')
    for f in ['docs/faq.html', 'docs/zh-TW/faq.html', 'docs/en/faq.html']:
        s = read(f)
        p = P()
        p.feed(s)
        ld = re.search(r'<script type="application/ld\+json">\s*(\{.*?\})\s*</script>', s, re.S)
        ldq = len(json.loads(ld.group(1))['mainEntity']) if ld else 0
        print(' ' + f)
        chk('html structure', not p.err and not p.stack, p.err[:1])
        chk('23 q / 5 groups / ld23',
            s.count('<details class="faq') == 23
            and s.count('<h3 class="faq-group"') == 5 and ldq == 23)
        chk('release line =150', 'v1.6.150' in s and '当前对应 v1.6.149' not in s
            and '目前對應 v1.6.149' not in s and 'matches v1.6.149' not in s)
        chk('skip-link + main + theme',
            'skip-link' in s and 'id="main"' in s and 'id="themeToggle"' in s)

    # 语言不得串页：各自特征句只应在自己那页
    lang_probe = {
        'docs/faq.html': [('回放当天路线', True), ('回放當日路線', False), ('replays that', False)],
        'docs/zh-TW/faq.html': [('回放當日路線', True), ('回放当天路线', False), ('replays that', False)],
        'docs/en/faq.html': [('replays that', True), ('回放当天路线', False), ('回放當日路線', False)],
    }
    print('[language isolation]')
    for f, ts in lang_probe.items():
        s = read(f)
        for t, want in ts:
            n = s.count(t)
            chk('%s : %s' % (os.path.basename(f), t), (n > 0) == want, 'count=%d' % n)

    print('[manual x39 多页]')
    MANUAL = ['index', 'start', 'interface', 'connections', 'beacon', 'messaging', 'maps',
              'stations', 'data', 'widgets', 'settings', 'platform', 'troubleshooting']
    BASES = [('docs/manual', 'docs/manual.html'),
             ('docs/zh-TW/manual', 'docs/zh-TW/manual.html'),
             ('docs/en/manual', 'docs/en/manual.html')]
    for base, old in BASES:
        # 旧单页必须是**跳转桩**（不是内容页，也不能 404）
        s_old = read(old)
        chk('旧单页转跳桩 ' + old,
            'http-equiv="refresh"' in s_old and 'manual/index.html' in s_old)
        bad_struct, no_theme, no_crumb, no_hreflang = [], [], [], []
        for name in MANUAL:
            f = '%s/%s.html' % (base, name)
            s = read(f)
            p = P()
            p.feed(s)
            if p.err or p.stack:
                bad_struct.append(name)
            if "localStorage.getItem('theme')" not in s or 'skip-link' not in s \
                    or 'rel="canonical"' not in s or '"@type": "TechArticle"' not in s:
                no_theme.append(name)
            if 'doc-crumb' not in s or 'manual-nav' not in s or 'doc-pager' not in s:
                no_crumb.append(name)
            if s.count('rel="alternate" hreflang=') != 4:
                no_hreflang.append(name)
        chk('%s: 13 页结构 OK' % base, not bad_struct, bad_struct)
        chk('%s: theme/skip/canonical/ld' % base, not no_theme, no_theme)
        chk('%s: crumb+tree+pager' % base, not no_crumb, no_crumb)
        chk('%s: hreflang x4/页' % base, not no_hreflang, no_hreflang)
    # 设置页：三语表格**互相对齐**且分组数为 15。
    #
    # ⚠ 行数**不写死**：这台是本月第三次被同一类问题咬 ——
    #   （v1.6.155 首页条数、v1.6.156 首页条数、这次设置页行数）。
    #   写死数字的表现永远是「加了设置项 → 内容是对的、检查是旧的」，
    #   而要守的不变量其实是**三语之间一致**（某语言的表格漏行才是真问题）。
    #   所以：三个语言的 (分组数, 行数) 必须彼此相同；行数下限取 150 兜住「整页空了」。
    set_stats = {}
    for base, _ in BASES:
        s = read(base + '/settings.html')
        set_stats[base] = (s.count('<section class="chapter'), s.count('<tr><td><b>'))
        chk('settings defaults present', 'rotate.aprs2.net' in s and '14580' in s)
    uniq = set(set_stats.values())
    chk('settings tables aligned across languages',
        len(uniq) == 1 and next(iter(uniq))[0] == 16 and next(iter(uniq))[1] >= 150,
        str(set_stats))
    # 任务式素材：真实报文 + m-steps（且不得误用首页 .steps）
    s = read('docs/manual/start.html')
    chk('real packet sample', 'BG7LZG-9&gt;APALOC,TCPIP*' in s)
    chk('m-steps used, .steps not', 'class="m-steps"' in s and 'class="steps"' not in s)
    chk('troubleshooting decision table', '症状 → 原因 → 动作' in read('docs/manual/troubleshooting.html'))
    chk('manual zh-TW 题式句', '症狀 → 原因 → 動作' in read('docs/zh-TW/manual/troubleshooting.html'))
    chk('manual en sentence', 'Symptom → cause → action' in read('docs/en/manual/troubleshooting.html'))

    print('[nav cross-links]')
    for f in ['docs/index.html', 'docs/zh-TW/index.html', 'docs/en/index.html',
              'docs/faq.html', 'docs/zh-TW/faq.html', 'docs/en/faq.html']:
        chk('manual link in ' + f, 'manual/index.html' in read(f))
    # 手册 12 内页必须能回首页/帮助中心（index 自身除外）
    for base, _ in BASES:
        s = read(base + '/start.html')
        chk('manual page -> faq + home', 'faq.html' in s and 'index.html' in s)
    # 手册页互相链接（分页器）
    s = read('docs/manual/start.html')
    chk('pager prev/next', 'pg-prev' in s and 'pg-next' in s)

    print('[seo]')
    ns = {'s': 'http://www.sitemaps.org/schemas/sitemap/0.9'}
    locs = [u.find('s:loc', ns).text
            for u in ET.parse(os.path.join(ROOT, 'docs/sitemap.xml')).getroot().findall('s:url', ns)]
    missing = []
    for l in locs:
        rel = l.replace('https://aprslocus.theez.top/', '') or 'index.html'
        if rel.endswith('/'):
            rel += 'index.html'
        if not os.path.exists(os.path.join(ROOT, 'docs', rel)):
            missing.append(rel)
    chk('sitemap entries reachable (%d)' % len(locs), not missing, missing)
    chk('sitemap manual x39', sum(1 for l in locs if '/manual/' in l) == 39,
        sum(1 for l in locs if '/manual/' in l))
    chk('robots -> sitemap',
        'Sitemap: https://aprslocus.theez.top/sitemap.xml' in read('docs/robots.txt'))
    # sitemap 里不得出现「自己声明 noindex」的页面：
    # guide.html（视频画面稿）写着 `noindex, follow`，却同时挂在 sitemap 里 ——
    # 这会让搜索控制台报「已提交的网址被 noindex 排除」，白提交还被判错。
    # 两者只能选一边：要么撤回 noindex，要么从 sitemap 拿掉（现在是后者）。
    noidx = []
    for l in locs:
        rel = l.replace('https://aprslocus.theez.top/', '') or 'index.html'
        if rel.endswith('/'):
            rel += 'index.html'
        p = os.path.join(ROOT, 'docs', rel)
        if os.path.exists(p) and re.search(
                r'<meta[^>]+name="robots"[^>]+noindex',
                io.open(p, encoding='utf-8').read()):
            noidx.append(rel)
    chk('sitemap 无 noindex 页', not noidx, noidx)

    print('[sponsors]')
    # 赞助名单的**唯一真源**是 docs/sponsors.json，展示面按语言分三处走：
    #   * 三个首页的静态块由 `tool/sync_sponsors_site.py` 渲染 —— 忘了跑脚本首页就落后；
    #   * `docs/guide.html`（解说页）的「赞助与算力支持」卡片是**手写的**，脚本不管它。
    #
    # 后者正是会悄悄漂移的那一种：加了赞助人、首页跟上了、解说页却少一位 ——
    # 页面照样打开、也没有任何报错（BG2EFX 就差点这样漏掉）。所以这里按真源
    # 逐条点名三个首页 + 解说页，**不写死条数**（写死的话每加一位都要改检查器，
    # 忘了改的表现是「检查失败但内容其实是对的」）。
    def _sp_pick(mapv, base, lang):
        """与 sync_sponsors_site.py / js/main.js 同一套回落：该语言 → 中文基准 → 英文。"""
        if isinstance(mapv, dict) and mapv.get(lang):
            return mapv[lang]
        if base:
            return base
        if isinstance(mapv, dict) and mapv.get('en'):
            return mapv['en']
        return ''

    def _sp_esc(v):
        """渲染时会被转义（同 sync_sponsors_site.py 的 esc / js 的 esc）——
        名单里将来真出现 `&`（如「A & B 群组」）时，拿原文去比会**假失败**，
        所以两种写法都算命中。"""
        return (str(v).replace('&', '&amp;').replace('<', '&lt;')
                .replace('>', '&gt;').replace('"', '&quot;'))

    def _sp_hit(name, s, tmpl):
        return any(tmpl % esc in s for esc in {name, _sp_esc(name)})

    try:
        _sp = json.loads(read('docs/sponsors.json'))
        ents = [e for e in (_sp.get('sponsors') or []) if e.get('name')]
    except Exception as ex:
        ents = []
        chk('sponsors.json 可解析', False, ex)

    miss = []
    for rel, lang in (('docs/index.html', 'zh'),
                      ('docs/zh-TW/index.html', 'zh-TW'),
                      ('docs/en/index.html', 'en')):
        s = read(rel)
        for e in ents:
            nm = _sp_pick(e.get('names'), e.get('name'), lang)
            if nm and not _sp_hit(nm, s, '<span class="c-name">%s</span>'):
                miss.append('%s 缺 %s' % (rel, nm))
    chk('赞助名单 %d 位 × 三语首页齐备' % len(ents), bool(ents) and not miss, miss[:3])

    g = read('docs/guide.html')
    gmiss = []
    for e in ents:
        nm = _sp_pick(e.get('names'), e.get('name'), 'zh')
        # 解说页的卡片是手写的，允许 `<span>呼号<em>备注</em></span>` 这种带小注的写法
        if nm and not any(re.search(r'<span>%s(?:</span>|<em>)' % re.escape(x), g)
                          for x in {nm, _sp_esc(nm)}):
            gmiss.append(nm)
    chk('解说页赞助卡片含全部 %d 位' % len(ents), bool(ents) and not gmiss, gmiss[:3])

    print('[friend links]')
    # 友链的唯一真源是 docs/links.json，静态渲染进三个语言页的**独立区块**
    # （tool/sync_friend_links_site.py），已**不再**塞在页脚里 ——
    # 曾经的页脚一行又挤又难看，现在是一整块 section（位于页脚之前）。
    # 这里逐条点名：忘了跑脚本 / 漏某个语言 / 又退回页脚 都会当场报。
    # 渲进页面是**静态**的（没有运行时 fetch 兜底），所以更得盯着。
    try:
        _lk = json.loads(read('docs/links.json'))
        flinks = [lk for lk in (_lk.get('links') or []) if lk.get('url')]
    except Exception as ex:
        flinks = []
        chk('links.json 可解析', False, ex)

    flabel = {'zh': '友情链接', 'zh-TW': '友情連結', 'en': 'Friendly Links'}
    fmiss = []
    for rel, lang in (('docs/index.html', 'zh'),
                      ('docs/zh-TW/index.html', 'zh-TW'),
                      ('docs/en/index.html', 'en')):
        s = read(rel)
        if '<!-- friends-sync -->' not in s:
            fmiss.append('%s 缺 friends-sync 块' % rel)
            continue
        if flabel[lang] not in s:
            fmiss.append('%s 缺标题「%s」' % (rel, flabel[lang]))
        # 独立区块（不在页脚里），且整块位于页脚注释之前
        if '<section class="section alt" id="friends">' not in s:
            fmiss.append('%s 缺友情链接独立 section' % rel)
        elif s.index('<!-- friends-sync -->') > s.index('<footer'):
            fmiss.append('%s 友链仍挤在页脚（应在页脚之前）' % rel)
        for lk in flinks:
            nm = _sp_pick(lk.get('name'), None, lang)
            if nm and not _sp_hit(nm, s, 'class="flink-name">%s</span>'):
                fmiss.append('%s 缺 %s' % (rel, nm))
    chk('友情链接 %d 条 × 三语独立区块齐备' % len(flinks), bool(flinks) and not fmiss, fmiss[:3])

    print('[css / js]')
    css = read('docs/css/style.css')
    cssb = re.sub(r'/\*.*?\*/', '', css, flags=re.S)
    chk('css braces balanced', cssb.count('{') == cssb.count('}'))
    # 对比度那条判据以前点的是几个写死的颜色值，现在颜色都收进 token 了，
    # 所以改成点 token 本身：浅色那套里必须还在（值可以对不上，名字不许丢）。
    chk('contrast fixes present',
        all(x in css for x in ['--text-faint: #5b6b85', '--cyan: #1d6fd0',
                               '--cyan-deep: #0369a1', '--accent: #e25700',
                               '--on-accent: #1a1207', '--font-mono', '--grad-text']))

    # ── 调色板只有一个源头：style.css 里那两块 token ────────────────────
    # 深色收成「一块 token 覆盖」之后，"深色规则数 >= 40" 这种数数的判据就
    # 失效了（越数越少，但页面其实是对的）。真正要钉的是两件事：
    #   1) 浅色那套 token 里每个**颜色**，深色块都必须重新定义 —— 漏一个就会
    #      在深底上露出浅色值（当年就是这么漏出白底描边的）；
    #   2) token 声明之外一个颜色字面量都不许有 —— 有也就意味着某处写死了
    #      颜色，切到另一套主题必成亮斑。唯一放行的是 mask 里的 #000。
    def _tok_decl(text):
        return dict(re.findall(r'^\s*(--[a-z0-9-]+)\s*:\s*([^;]+);', text, re.M))

    _blocks = {}
    for _m in re.finditer(r'(:root(?:\[data-theme="dark"\])?)\s*\{(.*?)\n\}', cssb, re.S):
        _blocks[_m.group(1)] = _m.group(2)
    light_tok = _tok_decl(_blocks.get(':root', ''))
    dark_tok = _tok_decl(_blocks.get(':root[data-theme="dark"]', ''))
    colourish = re.compile(r'#[0-9a-fA-F]{3,8}\b|rgba?\(|(?<![\w-])(?:white|black|silver|gray|grey)(?![\w-])')
    need_dark = [k for k, v in light_tok.items() if colourish.search(v)]
    chk('深色 token 覆盖浅色 token（%d 个颜色 token）' % len(need_dark),
        bool(need_dark) and all(k in dark_tok for k in need_dark),
        [k for k in need_dark if k not in dark_tok][:6])
    # 颜色字面量只允许出现在 token 声明行、和 mask 的那两行 #000 里
    literals = []
    for i, line in enumerate(cssb.split('\n')):
        if re.match(r'^\s*--[a-z0-9-]+\s*:', line):
            continue
        if re.search(r'#[0-9a-fA-F]{3,8}\b|rgba?\(', line):
            literals.append('L%d %s' % (i + 1, line.strip()[:70]))
    chk('token 之外无颜色字面量（mask 的 #000 除外）',
        all('#000' in x and 'mask-image' in x for x in literals), literals[:4])
    # 深色下必须用 token，不许写死 Colors.white 那种（这页是 CSS，同类问题是写死值）
    chk('style.css 里没有老卡片样式（功能清单在 features.css）',
        not re.search(r'^\s*\.cards?\s*[,{]', cssb, re.M))
    chk('help-center styles', all(x in css for x in ['.skip-link', '.faq-search', '.faq-group']))
    chk('manual multi-page styles',
        all(x in css for x in ['.doc-crumb', '.doc-pager', '.set-table',
                               '.m-kind', '.m-index-list', 'pre.pkt']))
    chk('manual 优化样式',
        all(x in css for x in ['.hdr-anchor', '.ms-results', '.m-related']))
    # 文档页优化：跨页搜索索引 / 标题永久链接 / 相关章节 / 缓存版本
    for base, _ in BASES:
        try:
            ix = json.load(io.open(os.path.join(ROOT, base, '_index.json'),
                                   encoding='utf-8'))
            chk('%s _index.json >= 50 条' % base, len(ix) >= 50, len(ix))
        except Exception as e:
            chk('%s _index.json 可解析' % base, False, e)
    bad_anchor = [b0 + '/' + n for b0, _ in BASES for n in MANUAL
                  if 'hdr-anchor' not in read(b0 + '/' + n + '.html')]
    chk('hdr-anchor 39 页全有', not bad_anchor, bad_anchor[:3])
    bad_rel = [b0 + '/' + n for b0, _ in BASES for n in MANUAL
               if 'm-related' not in read(b0 + '/' + n + '.html')]
    chk('m-related 39 页全有', not bad_rel, bad_rel[:3])
    chk('跨页搜索容器 + 脚本',
        all('manualResults' in read(b0 + '/start.html')
            and "fetch('_index.json')" in read(b0 + '/start.html') for b0, _ in BASES))
    # 版本号一改就得全站同步（浏览器缓存认这个），所以不只点两页，
    # 而是把 docs 下所有 html 扫一遍：每个文件只能有一种 style.css / main.js 版本。
    def _pins(pattern):
        got = {}
        for dirpath, _dirs, files in os.walk(os.path.join(ROOT, 'docs')):
            for fn in files:
                if fn.endswith('.html'):
                    s = io.open(os.path.join(dirpath, fn), encoding='utf-8').read()
                    for v in re.findall(pattern, s):
                        got.setdefault(v, []).append(os.path.relpath(
                            os.path.join(dirpath, fn), ROOT))
        return got

    css_pins, js_pins = _pins(r'style\.css\?v=(\d+)'), _pins(r'main\.js\?v=(\d+)')
    chk('css 缓存版本全站一致（style.css %s）' % ','.join(sorted(css_pins)),
        list(css_pins) == ['8'] and 'style.css?v=8' in read('docs/index.html'))
    chk('js 缓存版本全站一致（main.js %s）' % ','.join(sorted(js_pins)),
        list(js_pins) == ['8'])
    # 只挂独立页的 theme.css 也必须跟 style.css 同名版本
    STANDALONE = ("docs/promo.html", "docs/card.html", "docs/badge.html",
                  "docs/member-card.html", "docs/memorial.html", "docs/terms.html",
                  "docs/zh-TW/terms.html", "docs/en/terms.html")
    chk('theme.css 一版到底',
        len(set(re.findall(r'theme\.css\?v=(\d+)', read(f))[0] for f in STANDALONE)) == 1)
    # 这 8 页不挂 main.js，主题切换是另一份 js/theme.js。
    # 判据两层：这 8 页一处不多不少、版本还一致；别处的页面一根都不许碰。
    chk('独立页各一颗主题切换按钮（theme.js 同一版）',
        all(read(f).count('js/theme.js?v=') == 1 and 'id="themeToggle"' in read(f)
            and 'class="theme-toggle"' in read(f) and 'class="tic-sun"' in read(f)
            for f in STANDALONE) and
        len(set(re.findall(r'theme\.js\?v=(\d+)', read(f))[0] for f in STANDALONE)) == 1)
    chk('theme.js 只服务独立页（首页 / 文档页不碰）',
        all('theme.js' not in read(f) for f in
            ('docs/index.html', 'docs/zh-TW/index.html', 'docs/en/index.html',
             'docs/faq.html', 'docs/manual/start.html', 'docs/guide.html')))
    # 两块 token 在 style.css 和 theme.css 里各存了一份（独立页不挂 style.css），
    # 双份就得逐字比对，不然改一边忘一边 —— 这类漂移肉眼看不出来。
    _tb = {}
    for rel in ('docs/css/style.css', 'docs/css/theme.css'):
        t = re.sub(r'/\*.*?\*/', '', read(rel), flags=re.S)
        _tb[rel] = dict((m.group(1), m.group(2)) for m in
                        re.finditer(r'(:root(?:\[data-theme="dark"\])?)\s*\{(.*?)\n\}', t, re.S))
    chk('theme.css 的 token 与 style.css 逐字一致',
        _tb['docs/css/style.css'] == _tb['docs/css/theme.css'],
        [k for k in _tb['docs/css/style.css']
         if _tb['docs/css/theme.css'].get(k) != _tb['docs/css/style.css'][k]])
    chk('永久链接文案三语',
        '本节永久链接' in read('docs/manual/start.html')
        and '本節永久連結' in read('docs/zh-TW/manual/start.html')
        and 'Permalink to this section' in read('docs/en/manual/start.html'))
    chk('相关章节三语',
        '相关章节' in read('docs/manual/beacon.html')
        and '相關章節' in read('docs/zh-TW/manual/beacon.html')
        and 'Related sections' in read('docs/en/manual/beacon.html'))
    chk('JSON-LD dateModified', 'dateModified' in read('docs/manual/start.html'))

    js = read('docs/js/main.js')
    # 用 check_embedded_js 的状态机掩码（字符串 / 模板串 / 正则 / 注释），
    # 不要在这里用正则硬剥：main.js 里 `'"'` 这种「单引号里套双引号」
    # 会让朴素的 `"..."` 正则错配、把后续内容整段掩掉，括号数随之失真
    # —— 曾因此对本就平衡的 main.js 报了一次假 FAIL（已修）。
    j, _jerr = _mask_js(js)
    chk('js braces/parens balanced',
        j.count('{') == j.count('}') and j.count('(') == j.count(')'))
    chk('js theme + aria + null-safe canvas',
        all(x in js for x in ['themeToggle', 'aria-expanded', 'canvas ? canvas.getContext']))

    print()
    if FAILS:
        print('FAIL (%d): %s' % (len(FAILS), '; '.join(FAILS)))
        return 1
    print('ALL PASS')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
