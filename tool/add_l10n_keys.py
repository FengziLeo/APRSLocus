#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""往 6 个语言加 l10n 键（arb 真源 + 抽象类 + gen-l10n 产物），**幂等**。

## 为什么固化成工具

我（AI）在 1.6.165/166 这两轮里手写了 4 次「往 arb 追加键」的临时脚本，
每次都错在**同一个地方**：追加多个键时只在最后一个处理了逗号 ——

  * 追加 2~3 个键 → 第 1 个键行尾少逗号 → 整个 arb **JSON 语法坏掉**
    （`Expecting ',' delimiter`），而 `check_l10n_sync` 会以「解析失败」报出来。

手写这种「字符串拼 JSON」的活**必然**漂。所以做成工具：以后加键只改下面的 KEYS。

## 用法

    python3 tool/add_l10n_keys.py

改 KEYS 里的内容再跑即可；已存在的键会跳过（幂等），所以可以反复跑。
带占位符的键在 META 里声明（gen-l10n 需要 `@key.placeholders`）。
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

# ── 要加的键：key → (zh, zh_TW, en, ja, es, id) ──
KEYS = {
    # ── 启动权限体检（用户要求：「每次 APP 启动前检查权限，要不然用户关掉权限后
    # 可能会闪退。你做个提示」）──
    #
    # 只在**缺哪一项**时出现，一项不缺时全程静默。文案要说清「缺的是哪一项、
    # 什么功能用不了」，而不是光说「请授权」——用户刚在系统设置里关掉它，
    # 不说清是哪一项，他回去也找不到。
    'permCheckTitle': (
        '权限被关掉了', '權限被關掉了', 'Permissions are off',
        '権限がオフになっています', 'Hay permisos desactivados',
        'Izin dimatikan'),
    # 定位：地图与上报都靠它；也是「后台服务起不来」的那一项
    'permCheckLocation': (
        '定位权限没开，地图标不出位置，也不能上报。',
        '定位權限沒開，地圖標不出位置，也不能上報。',
        'Location is off. The map cannot show your position and nothing can be beaconed.',
        '位置情報の権限がオフです。地図に自分の位置が出ず、送信もできません。',
        'El permiso de ubicación está desactivado: el mapa no puede mostrar tu posición '
        'y no se puede balizar.',
        'Izin lokasi mati: peta tidak bisa menampilkan posisi dan tidak ada yang bisa dipancarkan.'),
    # 通知：常驻通知、消息与生命守护强提醒都靠它（Android 13 起才是运行时权限）
    'permCheckNotify': (
        '通知权限没开，提醒和生命守护告警都看不到。',
        '通知權限沒開，提醒和生命守護告警都看不到。',
        'Notifications are off. Reminders and the life-guard alarm will not show.',
        '通知の権限がオフです。リマインダーとライフアラームが表示されません。',
        'El permiso de notificaciones está desactivado: no se verán los avisos ni '
        'la alarma de vida.',
        'Izin notifikasi mati: pengingat dan alarm darurat tidak akan muncul.'),
    # ── 输入框历史（搜索框 / 服务器地址的「最近用过的」面板，见 lib/input_history.dart）──
    # 两个标题分开写：面板标题同时当按钮的长按提示，说「最近搜过的」比说
    # 「历史记录」更能说明点开是什么。
    'searchHistoryTitle': (
        '最近搜过的', '最近搜過的', 'Recent searches',
        '最近の検索', 'Búsquedas recientes', 'Pencarian terakhir'),
    'serverHistoryTitle': (
        '最近连过的服务器', '最近連過的伺服器', 'Recent servers',
        '最近接続したサーバー', 'Servidores recientes', 'Server terakhir'),
}

META = {
    'gpxExported': '{"placeholders": {"days": {"type": "String"}, "points": {"type": "String"}}}',
    'gpxSavedTo': '{"placeholders": {"path": {"type": "String"}}}',
    'audioTxNotSourceWarn': '{"placeholders": {"src": {"type": "String"}}}',
    'prunePreview': '{"placeholders": {"n": {"type": "String"}}}',
    'pruneConfirm': '{"placeholders": {"n": {"type": "String"}, "m": {"type": "String"}}}',
    'pruneDone': '{"placeholders": {"n": {"type": "String"}}}',
    'beaconCoarseForced': '{"placeholders": {"s": {"type": "String"}}}',
    'txNoFixKeptStatus': '{"placeholders": {"parts": {"type": "String"}}}',
    'connStatusSent': '{"placeholders": {"call": {"type": "String"}}}',
    'connTncStatusSent': '{"placeholders": {"arg": {"type": "String"}}}',
    'connAudioStatusSent': '{"placeholders": {"call": {"type": "String"}}}',
    'nDays': '{"placeholders": {"n": {"type": "String"}}}',
    'strategyTeammateOf': '{"placeholders": {"call": {"type": "String"}}}',
    'strategyUpdatedItem':
        '{"placeholders": {"call": {"type": "String"}, "kind": {"type": "String"}}}',
    'strategyDeletedItem':
        '{"placeholders": {"call": {"type": "String"}, "kind": {"type": "String"}}}',
    'strategyClearedMsg': '{"placeholders": {"call": {"type": "String"}}}',
    'strategySharedItem':
        '{"placeholders": {"call": {"type": "String"}, "kind": {"type": "String"}}}',
    'strategyAckPending': '{"placeholders": {"n": {"type": "int"}}}',
    'locationSendTo': '{"placeholders": {"call": {"type": "String"}}}',
    'locationPageInfo':
        '{"placeholders": {"n": {"type": "String"}, "m": {"type": "String"}}}',
    'shareStationSent': '{"placeholders": {"call": {"type": "String"}}}',
}


def _params(key):
    """从 META 里抠出这个键的占位符名字。"""
    raw = META.get(key)
    if not raw:
        return []
    try:
        return list(json.loads(raw).get('placeholders', {}).keys())
    except Exception:
        return []


def member(key):
    """产出的成员签名：无占位符 → `get key`；有 → `key(String a, String b)`。

    ⚠ 这是一处真实缺陷的修法（v1.6.177）：本函数以前一律写 getter，于是带占位符
    的键被写成 `String get x => "... {s}";` —— **本机** `S.of(context).x(y)` 报
    not_a_function，而 CI 的 `pub get` 会按 arb 重新生成产物，于是 CI 全绿、
    问题被盖住（正是本仓库最熟悉的「我这儿有错、CI 却是绿的」）。
    产物必须与 gen-l10n 同形：带占位符就是**带参数的方法**。
    """
    ps = _params(key)
    if not ps:
        return 'get %s' % key
    return '%s(%s)' % (key, ', '.join('String ' + x for x in ps))


def interp(key, text):
    """把 `{x}` 换成 Dart 插值 `$x`（与 gen-l10n 的产物一致）。"""
    for x in _params(key):
        text = text.replace('{%s}' % x, '$%s' % x)
    return text


def class_body(src, name):
    m = re.search(r'(?m)^(?:abstract )?class ' + re.escape(name) + r'\b', src)
    if not m:
        raise SystemExit('找不到类 ' + name)
    j = src.find('\n}\n', m.end())
    if j < 0:
        j = src.rfind('\n}')
    return m.end(), j


def add_lines(text, lines):
    """把若干 `  "key": value` 行插到顶层 } 之前。

    ⚠ 逗号规则是这里唯一的坑：插入的每一行**之间**都要有逗号，
    而**最后一行后面不能有**（紧接着就是 }）。
    """
    if not lines:
        return text
    i = text.rstrip().rfind('}')
    head = text[:i].rstrip()
    if head.endswith(','):
        head = head[:-1]          # 去掉原末尾逗号，最后统一按需补
    body = ',\n'.join(l.rstrip().rstrip(',') for l in lines)
    return head + ',\n' + body + '\n' + text[i:]


def main() -> int:
    if not KEYS:
        print('KEYS 是空的 —— 请先在脚本里填要加的键')
        return 0
    for lg in LANGS:
        p = os.path.join(ROOT, 'lib', 'l10n', 'app_%s.arb' % lg)
        t = io.open(p, encoding='utf-8', newline='').read()
        add = []
        for k, v in KEYS.items():
            if '"%s":' % k in t:
                continue
            add.append('  %s: %s' % (json.dumps(k, ensure_ascii=False),
                                     json.dumps(v[IDX[lg]], ensure_ascii=False)))
        for k, m in META.items():
            if '"@%s":' % k in t:
                continue
            add.append('  %s: %s' % (json.dumps('@' + k, ensure_ascii=False), m))
        if add:
            t = add_lines(t, add)
            io.open(p, 'w', encoding='utf-8', newline='').write(t)
        # 立刻验 JSON：拼错了就在这里炸，不要留到 check 脚本里才发现
        try:
            json.load(io.open(p, encoding='utf-8'))
        except Exception as e:
            print('%s arb 拼坏了: %s' % (lg, e))
            return 1
        print('%s arb ok（新增 %d 行）' % (lg, len(add)))

    # 抽象类
    p = os.path.join(ROOT, 'lib', 'l10n', 'app_localizations.dart')
    s = io.open(p, encoding='utf-8').read()
    code = []
    for k, v in KEYS.items():
        if re.search(r'String (?:get )?%s\b' % k, s):
            continue
        code.append("  /// No description provided for @%s.\n  ///\n"
                    "  /// In zh, this message translates to:\n  /// **'%s'**\n"
                    "  String %s;\n" % (k, v[0], member(k)))
    if code:
        _, j = class_body(s, 'AppLocalizations')
        s = s[:j] + '\n' + '\n'.join(code) + s[j:]
        io.open(p, 'w', encoding='utf-8').write(s)
    print('抽象类 +%d' % len(code))

    # 各语言实现
    for lg in LANGS:
        fn = ('app_localizations_zh.dart' if lg in ('zh', 'zh_TW')
              else 'app_localizations_%s.dart' % lg)
        p = os.path.join(ROOT, 'lib', 'l10n', fn)
        s = io.open(p, encoding='utf-8').read()
        b0, b1 = class_body(s, CLASSES[lg])
        code = []
        for k, v in KEYS.items():
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
