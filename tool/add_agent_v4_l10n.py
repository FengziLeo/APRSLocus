#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""注入「智能体 v4」文案：轮次用完时的兜底提示。

背景：智能体一轮对话里最多 [AgentService.maxToolRounds] 次工具往返。以前轮次
用完就**直接停在最后一个工具气泡上**（用户看到的是「调了几次工具就没下文」），
现在 [AgentService.send] 会再补一次「不带工具、只准说话」的收尾请求；那次请求
也没给出正文时才用这条文案兜底。

与 add_agent_v3_l10n.py 同一套路数（arb 真源 + 抽象类 + 6 个 gen-l10n 产物），
幂等：已存在的键会跳过，可反复跑。

用法：python3 tool/add_agent_v4_l10n.py
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
    'agentNoFinalAnswer': (
        '已达到本轮的连续操作次数上限，没能给出结论。再发一句「继续」让它接着做。',
        '已達到本輪的連續操作次數上限，沒能給出結論。再送一句「繼續」讓它接著做。',
        'Reached the per-turn limit for tool actions, so no conclusion could be '
        'produced. Send “continue” to let it carry on.',
        'このターンの連続操作回数の上限に達し、結論を出せませんでした。'
        '「続けて」と送ると続きを実行します。',
        'Se alcanzó el límite de acciones por turno y no se pudo dar una conclusión. '
        'Envía «continúa» para que siga.',
        'Batas aksi per giliran tercapai dan kesimpulan tidak bisa dibuat. '
        'Kirim "lanjutkan" agar ia meneruskan.'),
}

META = {}

ANCHOR = '"agentTool_http_request"'


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
