#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""注入「智能体 v3」文案：逐字回复（流式）+ 工具操作历史。

与 add_agent_v2_l10n.py 同一套路数（arb 真源 + 抽象类 + 6 个 gen-l10n 产物），
幂等：已存在的键会跳过，可反复跑。

为什么单独一个脚本而不是改 v2 的 DEFAULT：v2 已经跑过、键已在 arb 里，
再动它的 DATA 容易把「已经发布过的文案」改出不一致（同键不同语言版本）。

用法：python3 tool/add_agent_v3_l10n.py
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
    # ── 逐字回复（流式）──
    'agentStreamReply': ('逐字回复', '逐字回覆', 'Stream replies', '逐次表示',
                         'Respuesta progresiva', 'Balasan bertahap'),
    'agentStreamReplyDesc': (
        '模型边生成边显示。后端不支持流式时自动退回整段显示，不会少一句回复。',
        '模型邊生成邊顯示。後端不支援串流時自動退回整段顯示，不會少一句回覆。',
        'Show the text while the model is still writing it. If the backend cannot stream, '
        'the whole reply is shown at once instead — never fewer replies.',
        'モデルの生成に合わせて順次表示します。バックエンドがストリーム非対応なら一括表示に'
        '切り替わります（返答が減ることはありません）。',
        'Muestra el texto mientras el modelo lo escribe. Si el backend no admite streaming, '
        'se muestra la respuesta completa de una vez (nunca menos respuestas).',
        'Tampilkan teks selagi model menulisnya. Jika backend tidak mendukung streaming, '
        'balasan penuh ditampilkan sekaligus — jumlah balasan tidak berkurang.'),
    # ── 工具操作历史（智能体页的「工具操作历史」按钮 + 状态冒泡）──
    'agentToolHistory': ('工具操作历史', '工具操作歷史', 'Tool activity',
                         'ツール操作履歴', 'Historial de herramientas',
                         'Riwayat alat'),
    'agentToolHistoryEmpty': (
        '还没有工具操作记录。让智能体帮你做点事，这里会一条条记下来。',
        '還沒有工具操作記錄。讓智慧代理幫你做點事，這裡會一條條記下來。',
        'No tool activity yet. Ask the agent to do something and each call will show up here.',
        'ツール操作の履歴はまだありません。エージェントに何か頼むと、ここに記録されます。',
        'Aún no hay actividad de herramientas. Pídele algo al agente y cada llamada aparecerá aquí.',
        'Belum ada riwayat alat. Minta agen melakukan sesuatu dan setiap panggilan akan muncul di sini.'),
    'agentToolWorking': ('正在操作：{tool}', '正在操作：{tool}', 'Working: {tool}',
                         '実行中：{tool}', 'En curso: {tool}',
                         'Sedang berjalan: {tool}'),
    'agentToolDenied': ('已拒绝', '已拒絕', 'Denied', '拒否', 'Denegado',
                        'Ditolak'),
    'agentToolFailed': ('失败', '失敗', 'Failed', '失敗', 'Falló', 'Gagal'),
}

META = {
    'agentToolWorking': '{"placeholders": {"tool": {"type": "String"}}}',
}

ANCHOR = '"codeContributionTranslation"'


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
