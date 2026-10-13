#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""注入「台站详情 PHG 卡片」文案（功率 / 高度 / 增益 / 方向 / 全向）。

原 PHG 显示是一行灰字（`4W · 6.1m · 2dB · omni`），不显眼也不好读；改成一张
独立小卡片、四项各自带标签。与 add_agent_v3_l10n.py 同一套路数（arb 真源 +
抽象类 + 6 个 gen-l10n 产物），幂等：已存在的键会跳过，可反复跑。

用法：python3 tool/add_phg_detail_l10n.py
"""
import io
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANGS = ['zh', 'zh_TW', 'en', 'ja', 'es', 'id']
IDX = {l: i for i, l in enumerate(LANGS)}
CLASSES = {
    'zh': 'AppLocalizationsZh', 'zh_TW': 'AppLocalizationsZhTw',
    'en': 'AppLocalizationsEn', 'ja': 'AppLocalizationsJa',
    'es': 'AppLocalizationsEs', 'id': 'AppLocalizationsId',
}

# key → (zh, zh_TW, en, ja, es, id)
DATA = {
    'phgTitle': ('PHG 天线信息', 'PHG 天線資訊', 'PHG antenna', 'PHG アンテナ',
                 'Antena PHG', 'Antena PHG'),
    'phgPower': ('功率', '功率', 'Power', '出力', 'Potencia', 'Daya'),
    'phgHeight': ('天线高度', '天線高度', 'Height', '高さ', 'Altura', 'Tinggi'),
    'phgGain': ('增益', '增益', 'Gain', '利得', 'Ganancia', 'Penguatan'),
    'phgDirection': ('方向', '方向', 'Direction', '方向', 'Dirección', 'Arah'),
    'phgOmni': ('全向', '全向', 'Omni', '無指向', 'Omni', 'Omni'),
}

META = {}

ANCHOR = '"beaconPowerLabel"'


def _placeholders(key):
    raw = META.get(key)
    if not raw:
        return []
    return [(k, v['type']) for k, v in json.loads(raw).get('placeholders', {}).items()]


def member(key):
    ps = _placeholders(key)
    if not ps:
        return 'get %s' % key
    dart_t = {'int': 'int', 'String': 'String'}
    return '%s(%s)' % (key, ', '.join('%s %s' % (dart_t.get(t, 'String'), n) for n, t in ps))


def interp(key, text):
    for n, _ in _placeholders(key):
        text = text.replace('{%s}' % n, '$%s' % n)
    return text


def class_body(src, name):
    m = re.search(r'(?m)^(?:abstract )?class ' + re.escape(name) + r'\b', src)
    if not m:
        raise SystemExit('找不到类 ' + name)
    j = src.find('\n}\n', m.end())
    if j < 0:
        j = src.rfind('\n}')
    return m.end(), j


def main():
    for lg in LANGS:
        p = os.path.join(ROOT, 'lib', 'l10n', 'app_%s.arb' % lg)
        lines = io.open(p, encoding='utf-8').read().split('\n')
        lines = [ln for ln in lines
                 if not any(ln.strip().startswith('"%s"' % k) for k in DATA)]
        idx = next((i for i, ln in enumerate(lines)
                    if ln.strip().startswith(ANCHOR)), None)
        assert idx is not None, 'anchor not found in %s' % p
        block = []
        for k, v in DATA.items():
            block.append('  "%s": %s,' % (k, json.dumps(v[IDX[lg]], ensure_ascii=False)))
        for k, m in META.items():
            block.append('  "%s": %s,' % ('@' + k, m))
        lines[idx:idx] = block
        io.open(p, 'w', encoding='utf-8').write('\n'.join(lines))
        json.load(io.open(p, encoding='utf-8'))
        print('%s ok (+%d)' % (p, len(DATA)))

    p = os.path.join(ROOT, 'lib', 'l10n', 'app_localizations.dart')
    s = io.open(p, encoding='utf-8').read()
    code = []
    for k, v in DATA.items():
        if re.search(r'String (?:get )?%s\b' % k, s):
            continue
        code.append("  /// No description provided for @%s.\n  ///\n"
                    "  /// In zh, this message translates to:\n  /// **'%s'**\n"
                    "  String %s;\n"
                    % (k, v[0].replace('\n', ' ').replace('\r', ' '), member(k)))
    if code:
        _, j = class_body(s, 'AppLocalizations')
        s = s[:j] + '\n' + '\n'.join(code) + s[j:]
        io.open(p, 'w', encoding='utf-8').write(s)
    print('抽象类 +%d' % len(code))

    for lg in LANGS:
        fn = ('app_localizations_zh.dart' if lg in ('zh', 'zh_TW')
              else 'app_localizations_%s.dart' % lg)
        p = os.path.join(ROOT, 'lib', 'l10n', fn)
        s = io.open(p, encoding='utf-8').read()
        b0, b1 = class_body(s, CLASSES[lg])
        code = []
        for k, v in DATA.items():
            if re.search(r'String (?:get )?%s\b' % k, s[b0:b1]):
                continue
            code.append('  @override\n  String %s => %s;\n'
                        % (member(k),
                           json.dumps(interp(k, v[IDX[lg]]), ensure_ascii=False)))
        if code:
            s = s[:b1] + '\n' + '\n'.join(code) + s[b1:]
            io.open(p, 'w', encoding='utf-8').write(s)
        print('%s +%d' % (CLASSES[lg], len(code)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
