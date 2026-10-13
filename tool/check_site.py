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
        chk('cards/cl present (%d cards, %d/%d vers)' %
            (s.count('<article class="card reveal">'),
             len(vers) - len(missing), len(vers)),
            s.count('<article class="card reveal">') >= 10 and not missing)
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
                and 'data-rate="%d"' % stats['packetsPerMinute'] in s
                and 'id="tlPackets">%s<' % pk in s
                and 'id="tlRateNum">+%d<' % stats['packetsPerMinute'] in s)
            # 只报数字：上限/时间戳/进度条这类"像上传面板"的元信息都不要再出现
            chk('%s : 只留跳动数字（无时间戳/进度条）' % f,
                not any(x in s for x in ('tlStamp', 'tlInc', 'tlBar', 'tlNext', 'tl-bar')))
            # 读数之前要有一句邀请，并且**必须排在读数前面**：先说清这个数字是
            # 什么（累计报文总量），再让它跳。只判「有 hero-invite」抓不到顺序写反。
            inv = s.find('class="hero-invite"')
            st = s.find('id="heroTelemetry"')
            chk('%s : 邀请文案在读数之前' % f,
                inv > 0 and 'class="hi-mark"' in s and inv < st)
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
    chk('contrast fixes present',
        all(x in css for x in ['--text-faint: #5b6b85', '--cyan: #0369a1',
                               '--grad-text', 'font-size: 16px; color']))
    chk('dark theme rules >= 40', css.count('[data-theme="dark"]') >= 40,
        css.count('[data-theme="dark"]'))
    chk('new card grads c15-c18', all(('.c%d {' % i) in css for i in (15, 16, 17, 18)))
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
    chk('css 缓存版本 v7、无 v6 残留',
        'style.css?v=7' in read('docs/manual/start.html')
        and 'style.css?v=6' not in read('docs/manual/start.html')
        and 'style.css?v=7' in read('docs/index.html'))
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
