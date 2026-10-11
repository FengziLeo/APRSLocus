#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""注入「智能体长期记忆 + 对话压缩 + 工具标签」文案（6 语言）。

与 add_agent_v2_l10n.py 同一套路数（arb 真源 + 抽象类 + 6 个 gen-l10n 产物）。

用法：python3 tool/add_agent_memory_l10n.py
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
    'agentMemory': ('长期记忆', '長期記憶', 'Long-term memory', '長期記憶',
                    'Memoria a largo plazo', 'Memori jangka panjang'),
    'agentMemoryDesc': ('让智能体跨对话记住你的偏好与常用信息',
                        '讓智慧代理跨對話記住你的偏好與常用資訊',
                        'Let the agent remember your preferences across chats',
                        'エージェントに好みを会話をまたいで記憶させます',
                        'Permite al agente recordar tus preferencias entre chats',
                        'Biarkan agen mengingat preferensi Anda antar percakapan'),
    'agentMemoryOn': ('启用长期记忆', '啟用長期記憶', 'Enable long-term memory', '長期記憶を有効化',
                      'Activar memoria a largo plazo', 'Aktifkan memori jangka panjang'),
    'agentMemoryHint': (
        '智能体可自行调用「记住 / 忘记」工具，也可由你直接说「记住…」。记忆只存在本机。',
        '智慧代理可自行呼叫「記住 / 忘記」工具，也可由你直接說「記住…」。記憶只存在本機。',
        'The agent can call the remember/forget tools, or just take “remember …”. Stored on this device only.',
        'エージェントが記憶/忘却ツールを使えます。「…を覚えて」と頼んでも可。本機にのみ保存されます。',
        'El agente puede usar las herramientas de recordar/olvidar, o basta con decir «recuerda…». Solo en este dispositivo.',
        'Agen dapat memakai alat ingat/lupakan, atau cukup bilang "ingat …". Hanya tersimpan di perangkat ini.'),
    'agentMemoryEmpty': ('暂无记忆。对智能体说「记住…」即可添加。',
                         '暫無記憶。對智慧代理說「記住…」即可加入。',
                         'No memories yet. Tell the agent “remember …” to add one.',
                         'まだありません。「…を覚えて」と伝えると追加できます。',
                         'Aún no hay memorias. Dile al agente «recuerda…» para añadir una.',
                         'Belum ada memori. Bilang "ingat …" ke agen untuk menambah.'),
    'agentMemoryClear': ('清空全部记忆', '清除全部記憶', 'Clear all memories', 'すべての記憶を消去',
                         'Borrar todas las memorias', 'Hapus semua memori'),
    'agentMemoryClearConfirm': ('确定清空全部长期记忆？此操作不可撤销。',
                                '確定清除全部長期記憶？此操作無法復原。',
                                'Clear all long-term memories? This cannot be undone.',
                                '長期記憶をすべて消去しますか？元に戻せません。',
                                '¿Borrar todas las memorias? No se puede deshacer.',
                                'Hapus semua memori jangka panjang? Tidak dapat dibatalkan.'),
    'agentCompress': ('对话压缩', '對話壓縮', 'Conversation compression', '会話の圧縮',
                      'Compresión de conversación', 'Kompresi percakapan'),
    'agentCompressDesc': ('历史变长时自动把旧对话折叠成摘要，省上下文',
                          '歷史變長時自動把舊對話摺疊成摘要，節省上下文',
                          'Fold old turns into a summary when history grows, to save context',
                          '履歴が長くなると古い会話を要約に畳み、コンテキストを節約します',
                          'Pliega turnos antiguos en un resumen cuando crece el historial',
                          'Lipat obrolan lama jadi ringkasan saat riwayat memanjang'),
    'agentCompressOn': ('启用自动压缩', '啟用自動壓縮', 'Enable auto compression', '自動圧縮を有効化',
                        'Activar compresión automática', 'Aktifkan kompresi otomatis'),
    'agentCompressHint': (
        '超过约 40 条消息时自动压缩。摘要会保留在系统提示里，最近的对话不受影响。',
        '超過約 40 條訊息時自動壓縮。摘要會保留在系統提示裡，最近的對話不受影響。',
        'Compresses beyond ~40 messages. The summary stays in the system prompt; recent turns are untouched.',
        '約 40 件を超えると自動圧縮。要約はシステムプロンプトに残り、直近の会話は変わりません。',
        'Comprime a partir de ~40 mensajes. El resumen queda en el prompt del sistema.',
        'Mengompres di atas ~40 pesan. Ringkasan tetap di prompt sistem.'),
    'agentCompressNow': ('立即压缩', '立即壓縮', 'Compress now', '今すぐ圧縮',
                         'Comprimir ahora', 'Kompres sekarang'),
    'agentCompressNothing': ('没有可压缩的内容', '沒有可壓縮的內容', 'Nothing to compress',
                             '圧縮する内容がありません', 'Nada que comprimir', 'Tidak ada yang dikompres'),
    'agentCompressDone': ('已压缩对话', '已壓縮對話', 'Conversation compressed', '会話を圧縮しました',
                          'Conversación comprimida', 'Percakapan dikompres'),

    'agentAllowNetwork': ('允许联网请求', '允許聯網請求', 'Allow network requests', 'ネットワーク要求を許可',
                          'Permitir solicitudes de red', 'Izinkan permintaan jaringan'),
    'agentAllowNetworkDesc': (
        '允许智能体主动发起 HTTP 请求（GET / POST / PUT / DELETE…）。默认关闭；开启后每次请求仍需你确认。',
        '允許智慧代理主動發起 HTTP 請求（GET / POST / PUT / DELETE…）。預設關閉；開啟後每次請求仍需你確認。',
        'Let the agent make HTTP requests (GET / POST / PUT / DELETE…). Off by default; every request still asks you first.',
        'エージェントが HTTP リクエスト（GET / POST / PUT / DELETE…）を送れるようにします。既定はオフ。実行前に毎回確認します。',
        'Permite al agente hacer solicitudes HTTP (GET / POST / PUT / DELETE…). Desactivado por defecto; cada solicitud te pregunta antes.',
        'Biarkan agen membuat permintaan HTTP (GET / POST / PUT / DELETE…). Nonaktif secara bawaan; tiap permintaan tetap minta konfirmasi.'),

    # 工具名 → 可读称呼
    'agentTool_http_request': ('发起网络请求', '發起網路請求', 'Make a network request', 'ネットワーク要求',
                               'Hacer una solicitud de red', 'Buat permintaan jaringan'),
    'agentTool_save_memory': ('记住一条信息', '記住一則資訊', 'Remember a fact', '情報を記憶',
                              'Recordar un dato', 'Ingat sebuah fakta'),
    'agentTool_list_memories': ('查看记忆', '查看記憶', 'Read memories', '記憶を表示',
                               'Ver memorias', 'Lihat memori'),
    'agentTool_forget_memory': ('忘记一条信息', '忘記一則資訊', 'Forget a fact', '情報を忘却',
                               'Olvidar un dato', 'Lupakan sebuah fakta'),
}

ANCHOR = '"codeContributionTranslation"'


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
                    "  String get %s;\n"
                    % (k, v[0].replace('\n', ' ').replace('\r', ' '), k))
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
            code.append('  @override\n  String get %s => %s;\n'
                        % (k, json.dumps(v[IDX[lg]], ensure_ascii=False)))
        if code:
            s = s[:b1] + '\n' + '\n'.join(code) + s[b1:]
            io.open(p, 'w', encoding='utf-8').write(s)
        print('%s +%d' % (CLASSES[lg], len(code)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
