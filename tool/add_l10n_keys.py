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
    # ── 副链路（APRSNETCN）卡片 ──
    #
    # 独立于主连接卡：这条连接只收不发，与主链路同时在线。三个标签各自说清
    # 一件事（这条链路是什么 / 开关 / 当前状态），说明文字放在卡片底部。
    'acnCardTitle': (
        'APRSNETCN 副链路', 'APRSNETCN 副鏈路', 'APRSNETCN second link',
        'APRSNETCN 副リンク', 'Enlace secundario APRSNETCN',
        'Tautan kedua APRSNETCN'),
    'acnCardSubtitle': (
        '与主链路同时在线，只收不发。',
        '與主鏈路同時在線，只收不發。',
        'Runs alongside the main link. Receive only.',
        'メイン回線と同時に接続します。受信のみです。',
        'Funciona junto al enlace principal. Solo recibe.',
        'Berjalan bersama tautan utama. Hanya menerima.'),
    'acnLinkSwitch': (
        '同时连接 APRSNETCN', '同時連線 APRSNETCN',
        'Also connect to APRSNETCN', 'APRSNETCN にも同時接続',
        'Conectar también a APRSNETCN', 'Hubungkan juga ke APRSNETCN'),
    'acnLinkStatus': (
        '副链路', '副鏈路', 'Second link', '副リンク',
        'Enlace secundario', 'Tautan kedua'),
    'acnLinkNote': (
        '发报文只走主链路。这条链路收来的台站会标成来自服务器，也不做网关转递。',
        '發報文只走主鏈路。這條鏈路收來的台站會標成來自伺服器，也不做閘道轉遞。',
        'Sending stays on the main link. Stations heard here are marked as '
            'coming from the server and are never gatewayed.',
        '送信はメイン回線のみです。ここで受信した局はサーバー由来として表示され、'
            'ゲートウェイ転送は行いません。',
        'El envío va solo por el enlace principal. Las estaciones recibidas '
            'aquí se marcan como del servidor y no se reenvían.',
        'Pengiriman tetap di tautan utama. Stasiun yang diterima di sini '
            'ditandai berasal dari server dan tidak diteruskan.'),
    'acnAccountNote': (
        '服务器发给白名单呼号的账号口令。留空就只按 passcode 收报文。',
        '伺服器發給白名單呼號的帳號密碼。留空就只按 passcode 收報文。',
        'Account and password issued by the server. Leave both empty to '
            'receive on the passcode alone.',
        'サーバーがホワイトリストの局に発行するアカウントとパスワードです。'
            '空欄なら passcode のみで受信します。',
        'Cuenta y contraseña que emite el servidor. Si se dejan vacías, se '
            'recibe solo con el passcode.',
        'Akun dan kata sandi dari server. Kosongkan keduanya untuk menerima '
            'dengan passcode saja.'),
}

META = {
    'acnSyncDone': '{"placeholders": {"total": {"type": "String"}, "added": {"type": "String"}}}',
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
