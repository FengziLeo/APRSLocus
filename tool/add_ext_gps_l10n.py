#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""外接 GPS 定位来源（蓝牙 SPP 上的 NMEA 0183）的两个文案键。

## 为什么单独一个脚本、而且自己写产物

本仓库的约定是**每个功能一批** `tool/add_*_l10n.py`：键与 6 语译文放在同一个
文件里，翻译的人一眼看全（见 `tool/add_pkwdwpl_l10n.py`）。这次要加的只有两个
键 —— 位置来源名（`_posSourceLabel`）与位置状态行（`localizedLocationStatus`）：

  * `posSrcSpp`      —— 「定位来源」那一行现在是外接模块时显示的名字；
  * `locationExtGps` —— `locStatus = '外接 GPS（蓝牙）'` 的本地化文案。

⚠ 本机没有 Flutter SDK，`flutter gen-l10n` 跑不了。所以本脚本**自己**往
committed 的产物（`lib/l10n/app_localizations*.dart`）里插同形成员 —— 这与
`tool/l10n_patch_gen.py` 的分工不同（那个按前缀补产物），但结果必须一样：
只在 arb 里加键，本机 `S.of(context).xxx` 就报 undefined_getter，而 CI 的
`pub get` 会按 arb 重新生成产物、把问题盖成绿的（本仓库最熟悉的
「我这儿有错、CI 却是绿的」）。`tool/check_l10n_sync.py` 是这条链的判据：
arb ↔ 产物 ↔ 代码用到的键，三者都得对得上。

两个键都是**无占位符的 getter**，所以这里只处理 getter（与 `member()` 同形）。
幂等：已存在的键跳过，可反复跑。
"""
import io
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANGS = ['zh', 'zh_TW', 'en', 'ja', 'es', 'id']
CLASSES = {
    'zh': 'AppLocalizationsZh', 'zh_TW': 'AppLocalizationsZhTw',
    'en': 'AppLocalizationsEn', 'ja': 'AppLocalizationsJa',
    'es': 'AppLocalizationsEs', 'id': 'AppLocalizationsId',
}
# 产物文件：zh 与 zh_TW 两个类同在一个文件里（见 TARGETS 的用法）
FILES = ('app_localizations_zh.dart', 'app_localizations_en.dart',
         'app_localizations_es.dart', 'app_localizations_id.dart',
         'app_localizations_ja.dart')

# key → (zh, zh_TW, en, ja, es, id)
KEYS = {
    # 定位来源名。与 posSrcSim / posSrcGarmin / posSrcPhone 并列的第四档，
    # 出现在信标上报页「定位来源」那一行（lib/settings_pages.dart）。
    'posSrcSpp': (
        '外接 GPS 模块', '外接 GPS 模組',
        'external GPS module',
        '外付け GPS モジュール',
        'módulo GPS externo',
        'modul GPS eksternal',
    ),
    # 位置状态行。与 locationGarmin（佳明 LiveTrack）/ locationCoarse（网络定位）
    # 同一张白名单：**必须**登记，否则非中文界面会漏出中文（lib/widgets.dart 里
    # 是 value == '…' 的白名单，tool/check_pos_quality.py 会核）。
    'locationExtGps': (
        '外接 GPS（蓝牙）', '外接 GPS（藍牙）',
        'external GPS (Bluetooth)',
        '外付け GPS（Bluetooth）',
        'GPS externo (Bluetooth)',
        'GPS eksternal (Bluetooth)',
    ),
}


def read(p, newline=None):
    return io.open(p, encoding='utf-8', newline=newline).read()


def write(p, s, newline=None):
    io.open(p, 'w', encoding='utf-8', newline=newline).write(s)


def add_lines(text, lines):
    """把若干 `  "key": value` 行插到顶层 } 之前（与 add_l10n_keys.py 同形）。

    ⚠ 逗号规则是这里唯一的坑：插入的行**之间**都要有逗号，最后一行后面**不能**有
    （紧接着就是 }）。手写这种「字符串拼 JSON」必然漂 —— 所以统一在这里处理，
    拼完立刻用 json.load 验一遍。
    """
    if not lines:
        return text
    i = text.rstrip().rfind('}')
    head = text[:i].rstrip()
    if head.endswith(','):
        head = head[:-1]
    body = ',\n'.join(l.rstrip().rstrip(',') for l in lines)
    return head + ',\n' + body + '\n' + text[i:]


def class_body(src, name):
    """返回某个类的成员区间的起点与终点（成员都插在终点前）。

    终点取 `\\n}\\n`（**列 0** 的 }，即类的收尾）：成员内部的 } 都带缩进，
    所以不会误取 —— 产物文件里每个类都恰好以这种收尾结束（zh 文件里两个类
    各一处）。找不到就直接失败，不做「猜一个 rfind」的兜底：那会在 zh 文件里
    把 zh_TW 类的收尾当成 zh 类的（成员插错类，analyze 才发现）。
    """
    m = re.search(r'(?m)^(?:abstract )?class ' + re.escape(name) + r'\b', src)
    if not m:
        raise SystemExit('找不到类 ' + name)
    j = src.find('\n}\n', m.end())
    if j < 0:
        raise SystemExit('类 %s 的收尾 `\\n}\\n` 没找到 —— 产物排版变了？' % name)
    return m.end(), j


def main() -> int:
    # ── ① ARB（真源）──
    for lg in LANGS:
        p = os.path.join(ROOT, 'lib', 'l10n', 'app_%s.arb' % lg)
        t = read(p, newline='')
        add = []
        for k, v in KEYS.items():
            if '"%s":' % k in t:
                continue
            add.append('  %s: %s' % (json.dumps(k, ensure_ascii=False),
                                     json.dumps(v[LANGS.index(lg)],
                                                ensure_ascii=False)))
        if add:
            write(p, add_lines(t, add), newline='')
        try:
            json.loads(read(p))
        except Exception as e:      # 拼坏了就在这里炸，不要留到 check 脚本
            print('%s arb 拼坏了: %s' % (lg, e))
            return 1
        print('%-22s arb ok（+%d 键）' % ('app_%s.arb' % lg, len(add)))

    # ── ② 抽象类 ──
    p = os.path.join(ROOT, 'lib', 'l10n', 'app_localizations.dart')
    s = read(p)
    code = []
    for k, v in KEYS.items():
        if re.search(r'String (?:get )?%s\b' % k, s):
            continue
        code.append("  /// 外接 GPS 模块（蓝牙 SPP / NMEA 0183）。\n  ///\n"
                    "  /// In zh, this message translates to:\n  /// **'%s'**\n"
                    "  String get %s;\n" % (v[0], k))
    if code:
        _, j = class_body(s, 'AppLocalizations')
        s = s[:j] + '\n' + '\n'.join(code) + s[j:]
        write(p, s)
    print('%-22s 抽象类 +%d' % ('app_localizations.dart', len(code)))

    # ── ③ 6 个具体类（按类分段，从后往前插，前面的行号才不会失效）──
    for fname in FILES:
        p = os.path.join(ROOT, 'lib', 'l10n', fname)
        s = read(p)
        lines = s.split('\n')
        heads = [i for i, l in enumerate(lines)
                 if l.startswith('class AppLocalizations')]
        heads.append(len(lines))
        total = 0
        for a, b in reversed(list(zip(heads, heads[1:]))):
            seg = lines[a:b]
            cname = seg[0].split()[1]
            lg = next((k for k, v in CLASSES.items() if v == cname), '')
            if not lg:
                continue
            body = '\n'.join(seg)
            miss = [k for k in KEYS
                    if not re.search(r'String (?:get )?%s\b' % k, body)]
            if not miss:
                continue
            ai = len(seg) - 1
            while ai >= 0 and seg[ai].strip() != '}':
                ai -= 1
            if ai <= 0:
                raise SystemExit('%s / %s 里找不到收尾的 }' % (fname, cname))
            add = []
            for k in miss:
                add += ['', '  @override',
                        "  String get %s => '%s';" % (
                            k, KEYS[k][LANGS.index(lg)]
                            .replace('\\', '\\\\').replace("'", r"\'")
                            .replace('$', r'\$'))]
            add.append('')      # 收尾前留一个空行（与产物既有排版一致）
            if ai > 0 and seg[ai - 1].strip() == '':
                del add[0]      # 收尾前本来就是空行 —— 别再插一个变成两行
            seg[ai:ai] = add
            lines[a:b] = seg
            total += len(miss)
        write(p, '\n'.join(lines))
        print('%-22s 产物 +%d' % (fname, total))
    return 0


if __name__ == '__main__':
    sys.exit(main())
