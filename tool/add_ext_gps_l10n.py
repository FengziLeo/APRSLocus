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

# 带占位符的键：key → {占位符: 类型}。gen-l10n 的产物里这种键是**带参方法**
# （`String x(String a) { return '...$a...'; }`）而不是 getter —— 写错成本形，
# 本机 analyze 会报 not_a_function，而 CI 的 pub get 重新生成产物后又看不见。
# 带占位符的键还必须在**模板 arb** 里有自己的 `@key` 元数据（gen-l10n 靠它定
# 参数类型；没有就按 Object 生成，产物与提交的那份对不上），下面的 ①b 会写。
PLACEHOLDERS = {
    'extGpsStats': {'rx': 'String'},
    'beaconSppNext': {'s': 'String'},
}

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
    # ── 数据来源卡里的一行（与 PKWDWPL 同类：设备链路、只收不发） ──
    'dataSourceNmeaGps': (
        '外接 GPS（蓝牙）', '外接 GPS（藍牙）',
        'External GPS (Bluetooth)',
        '外付け GPS（Bluetooth）',
        'GPS externo (Bluetooth)',
        'GPS eksternal (Bluetooth)',
    ),
    'dataSourceNmeaGpsDesc': (
        '读取 GPS 模组输出的 NMEA 0183 定位语句，作为本机位置来源（只收不发）',
        '讀取 GPS 模組輸出的 NMEA 0183 定位語句，作為本機位置來源（只收不發）',
        'Read NMEA 0183 position sentences from a GPS module and use them as this '
        'device own position (receive-only)',
        'GPS モジュールが出力する NMEA 0183 の測位文を読み、この端末自身の位置として'
        '使います（受信のみ）',
        'Lee las sentencias de posición NMEA 0183 de un módulo GPS y las usa como '
        'posición de este dispositivo (solo recepción)',
        'Baca kalimat posisi NMEA 0183 dari modul GPS dan pakai sebagai posisi '
        'perangkat ini (hanya terima)',
    ),
    'dataSourceNmeaGpsHint': (
        '这条链路供的是**本机位置**（不是别人的报文）：接上后位置优先用它，'
        '模组断流 30 秒后自动交回手机 GPS',
        '這條鏈路供的是**本機位置**（不是別人的報文）：接上後位置優先用它，'
        '模組斷流 30 秒後自動交回手機 GPS',
        'This link supplies **your own position** (not other stations packets): it '
        'takes priority once connected, and the phone GPS takes over again 30 '
        'seconds after the module stops sending',
        'このリンクが供給するのは**この端末の位置**です（他局のパケットではありません）。'
        '接続すると優先的に使われ、モジュールの送信が 30 秒止まるとスマートフォンの GPS '
        'に戻ります',
        'Este enlace aporta **tu propia posición** (no los paquetes de otras '
        'estaciones): pasa a tener prioridad al conectar, y el GPS del teléfono '
        'vuelve a asumir 30 segundos después de que el módulo deje de enviar',
        'Tautan ini memasok **posisi perangkat ini** (bukan paket stasiun lain): '
        'begitu tersambung ia diprioritaskan, dan GPS ponsel kembali mengambil alih '
        '30 detik setelah modul berhenti mengirim',
    ),
    # ── 设备页（与 PKWDWPL 设备页同构） ──
    'extGpsDeviceTitle': (
        '外接 GPS', '外接 GPS',
        'External GPS',
        '外付け GPS',
        'GPS externo',
        'GPS eksternal',
    ),
    'extGpsDeviceDesc': (
        '蓝牙 SPP / 串口上的 NMEA 0183 位置来源',
        '藍牙 SPP / 串列埠上的 NMEA 0183 位置來源',
        'NMEA 0183 position source over Bluetooth SPP or serial',
        'Bluetooth SPP / シリアル経由の NMEA 0183 位置ソース',
        'Fuente de posición NMEA 0183 por Bluetooth SPP o serie',
        'Sumber posisi NMEA 0183 lewat Bluetooth SPP atau serial',
    ),
    'extGpsBindTitle': (
        '设备与连接', '裝置與連線',
        'Device and connection',
        'デバイスと接続',
        'Dispositivo y conexión',
        'Perangkat dan koneksi',
    ),
    'extGpsBindSubtitle': (
        '扫描已配对设备并绑定（与 TNC / PKWDWPL 同一套蓝牙权限）',
        '掃描已配對裝置並綁定（與 TNC / PKWDWPL 同一套藍牙權限）',
        'Scan paired devices and bind one (same Bluetooth permission as '
        'TNC / PKWDWPL)',
        'ペアリング済みのデバイスをスキャンしてバインドします（TNC / PKWDWPL と'
        '同じ Bluetooth 権限）',
        'Escanea dispositivos emparejados y vincula uno (mismo permiso de Bluetooth '
        'que TNC / PKWDWPL)',
        'Pindai perangkat yang sudah dipasangkan lalu ikat (izin Bluetooth sama '
        'dengan TNC / PKWDWPL)',
    ),
    'extGpsTip': (
        '接上后位置优先用模组（常架在车顶或窗外，比手机与手表准）；'
        '拿不到新定位 30 秒后自动交回手机 GPS。',
        '接上後位置優先用模組（常架在車頂或窗外，比手機與手錶準）；'
        '拿不到新定位 30 秒後自動交回手機 GPS。',
        'Once connected the position comes from the module first (it usually sits '
        'on the roof or by a window, so it beats the phone and the watch); the '
        'phone GPS takes over again 30 seconds after the last fix.',
        '接続後はモジュールの位置を優先します（屋根や窓辺に置くことが多く、'
        'スマートフォンや時計より正確）。最後の測位から 30 秒たつとスマートフォンの GPS '
        'に戻ります。',
        'Al conectar, la posición sale primero del módulo (suele ir en el techo o '
        'junto a una ventana, así que es más preciso que el teléfono y el reloj); '
        'el GPS del teléfono vuelve a asumir 30 segundos después de la última '
        'posición.',
        'Setelah tersambung, posisi diambil dari modul lebih dulu (biasanya dipasang '
        'di atap atau dekat jendela, sehingga lebih akurat daripada ponsel dan jam); '
        'GPS ponsel kembali mengambil alih 30 detik setelah posisi terakhir.',
    ),
    'extGpsReadOnly': (
        '只收不发：模组只输出位置，不参与发射',
        '只收不發：模組只輸出位置，不參與發射',
        'Receive-only: the module only outputs position and never transmits',
        '受信のみ：モジュールは位置を出力するだけで送信には関与しません',
        'Solo recepción: el módulo solo emite posición y nunca transmite',
        'Hanya terima: modul hanya mengeluarkan posisi dan tidak ikut memancar',
    ),
    'extGpsStatTitle': (
        '定位接收', '定位接收',
        'Position reception',
        '測位の受信',
        'Recepción de posición',
        'Penerimaan posisi',
    ),
    # 带占位符：产物里是带参方法（见上面的 PLACEHOLDERS）
    'extGpsStats': (
        '已收定位 {rx} 条', '已收定位 {rx} 條',
        '{rx} positions received',
        '測位を {rx} 件受信',
        '{rx} posiciones recibidas',
        '{rx} posisi diterima',
    ),
    'extGpsStatNoFix': (
        '语句有效但还没定上', '語句有效但還沒定上',
        'Valid sentences, no fix yet',
        '文は有効だが未測位',
        'Sentencias válidas sin posición',
        'Kalimat valid tetapi belum ada posisi',
    ),
    'extGpsStatMismatch': (
        '校验和不符', '校驗和不符',
        'Checksum mismatches',
        'チェックサム不一致',
        'Discrepancias de suma',
        'Ketidakcocokan checksum',
    ),
    'extGpsStatRejected': (
        '丢弃/无效语句', '丟棄/無效語句',
        'Dropped or invalid sentences',
        '破棄/無効な文',
        'Sentencias descartadas o inválidas',
        'Kalimat dibuang atau tidak valid',
    ),
    'extGpsStatIgnored': (
        '其它 NMEA 语句（已忽略）', '其它 NMEA 語句（已忽略）',
        'Other NMEA sentences (ignored)',
        'その他の NMEA 文（無視）',
        'Otras sentencias NMEA (ignoradas)',
        'Kalimat NMEA lain (diabaikan)',
    ),
    'extGpsSatellites': (
        '卫星', '衛星',
        'Satellites',
        '衛星',
        'Satélites',
        'Satelit',
    ),
    'extGpsAccuracy': (
        '精度', '精度',
        'Accuracy',
        '精度',
        'Precisión',
        'Akurasi',
    ),
    'extGpsWaitingFix': (
        '已连接，正在搜星（还没有一次可用定位）',
        '已連線，正在搜星（還沒有一次可用定位）',
        'Connected, acquiring satellites (no usable fix yet)',
        '接続済み、衛星を捕捉中（まだ有効な測位がありません）',
        'Conectado, buscando satélites (aún sin posición utilizable)',
        'Tersambung, mencari satelit (belum ada posisi yang dapat dipakai)',
    ),
    'extGpsSilent': (
        '已连接，但没有收到任何语句（查供电 / 是否被别的应用占着）',
        '已連線，但沒有收到任何語句（檢查供電 / 是否被別的應用佔用）',
        'Connected but no sentences at all (check power and whether another app '
        'holds the device)',
        '接続済みですが文が一切届きません（給電と、他のアプリが占有していないかを'
        '確認してください）',
        'Conectado pero sin ninguna sentencia (comprueba la alimentación y si otra '
        'aplicación ocupa el dispositivo)',
        'Tersambung tetapi tidak ada kalimat sama sekali (periksa daya dan apakah '
        'aplikasi lain memakai perangkat itu)',
    ),
    'extGpsLogEmpty': (
        '暂无外接 GPS 日志', '暫無外接 GPS 日誌',
        'No external GPS log yet',
        '外付け GPS のログはまだありません',
        'Aún no hay registro del GPS externo',
        'Belum ada log GPS eksternal',
    ),
    # 校验严格度：**不能复用 pkwdwpl 的键** —— 那个的说明写的是「默认关闭」
    # （电台固件常与手册有出入），而模组按标准发语句，这里的默认是**开**。
    'extGpsStrictChecksum': (
        '严格校验和（不符即丢弃）', '嚴格校驗和（不符即丟棄）',
        'Strict checksum (drop mismatches)',
        '厳格なチェックサム（不一致は破棄）',
        'Suma de verificación estricta (descartar discrepancias)',
        'Checksum ketat (buang yang tidak cocok)',
    ),
    'extGpsStrictChecksumTip': (
        '默认开启：GPS 模组按标准发语句，校验和不符基本只有线路噪声一种解释 ——'
        '整条丢弃，别让一个坏字节把定位带偏。少数杂牌模组确实会发错校验和，'
        '那时把这里关掉（丢弃条数与日志会一直显示）。',
        '預設開啟：GPS 模組按標準送語句，校驗和不符基本上只有線路雜訊一種解釋 ——'
        '整條丟棄，別讓一個壞位元把定位帶偏。少數雜牌模組確實會送錯校驗和，'
        '那時把這裡關掉（丟棄條數與日誌會一直顯示）。',
        'On by default: a GPS module sends standard sentences, so a checksum '
        'mismatch almost always means line noise — the sentence is dropped so a '
        'single bad byte cannot skew the position. A few cheap modules really do '
        'send a wrong checksum; turn this off for those (the drop counter and log '
        'stay visible).',
        '既定でオン：GPS モジュールは規格どおりの文を送るため、チェックサム不一致は'
        'ほぼ配線ノイズです。1 バイトの破損で測位がずれないよう文ごと破棄します。'
        '安価なモジュールには実際に誤ったチェックサムを送るものもあり、'
        'その場合はここをオフにしてください（破棄数とログは表示され続けます）。',
        'Activado por defecto: un módulo GPS envía sentencias estándar, así que una '
        'discrepancia de suma casi siempre significa ruido en la línea: se descarta '
        'la sentencia para que un solo byte defectuoso no desvíe la posición. '
        'Algunos módulos baratos sí envían una suma incorrecta; desactívalo en ese '
        'caso (el contador de descartes y el registro siguen visibles).',
        'Aktif secara bawaan: modul GPS mengirim kalimat standar, jadi '
        'ketidakcocokan checksum hampir selalu berarti derau pada jalur — '
        'kalimatnya dibuang agar satu byte rusak tidak membuat posisi melenceng. '
        'Sebagian modul murah memang mengirim checksum yang salah; matikan ini '
        'untuk modul seperti itu (penghitung pembuangan dan log tetap terlihat).',
    ),
    # ── 位置来源那一组 / 设备占用 ──
    'ownSourceExtGpsLive': (
        '外接模块供位（手机 GPS 已让位）', '外接模組供位（手機 GPS 已讓位）',
        'Module supplying position (phone GPS stood down)',
        'モジュールが位置を供給中（スマートフォン GPS は待機）',
        'El módulo aporta la posición (el GPS del teléfono se aparta)',
        'Modul memasok posisi (GPS ponsel mundur)',
    ),
    'deviceInUseByOther': (
        '已被其它链路占用，不能重复绑定', '已被其它鏈路佔用，不能重複綁定',
        'Already used by another link, cannot bind twice',
        '他のリンクが使用中のため重複バインドできません',
        'Ya lo usa otro enlace, no se puede vincular dos veces',
        'Sudah dipakai tautan lain, tidak bisa diikat dua kali',
    ),
    # ── 信标横杠上的「来源档位」（BeaconPhase.spp） ──
    #
    # 与 beaconGarminSource / beaconGarminNext 并列的第四档：位置来自外接模块
    # 时，横杠必须把**来源**说清楚（否则用户会以为发的是手机定位）。与佳明那
    # 两键的区别只有一个：模块不带心率，所以没有 ❤ 字段。
    'beaconSppSource': (
        '外接 GPS 上报中', '外接 GPS 上報中',
        'Beaconing from external GPS',
        '外付け GPS から送信',
        'Balizando desde GPS externo',
        'Memancarkan dari GPS eksternal',
    ),
    # 带占位符：产物里是带参方法（见上面的 PLACEHOLDERS）
    'beaconSppNext': (
        '外接 GPS 上报 · {s}', '外接 GPS 上報 · {s}',
        'External GPS · {s}',
        '外付け GPS · {s}',
        'GPS externo · {s}',
        'GPS eksternal · {s}',
    ),
}


def _params(key):
    """这个键的占位符名字（保持声明顺序）。"""
    return list(PLACEHOLDERS.get(key, {}).keys())


def member(key):
    """产出的成员签名：无占位符 → `get key`；有 → `key(String a, String b)`。"""
    ps = _params(key)
    if not ps:
        return 'get %s' % key
    return '%s(%s)' % (key, ', '.join('String ' + x for x in ps))


def interp(key, text):
    """把 `{x}` 换成 Dart 插值 `$x`（与 gen-l10n 的产物一致）。"""
    for x in _params(key):
        text = text.replace('{%s}' % x, '$%s' % x)
    return text


def esc(v):
    """产物里是单引号字符串：转义反斜杠、单引号与 $。"""
    return v.replace('\\', '\\\\').replace("'", r"\'").replace('$', r'\$')


def members(key, text):
    """产物里的成员文本：getter 一行；带占位符的是 gen-l10n 那种多行方法。

    ⚠ 顺序要紧：**先**转义字面量里的 `$`（如 `$PKWDWPL`），**再**把 `{rx}` 换成
    插值 `$rx`。反过来的话（先插值再转义）会把插值本身也转义掉，产物就变成
    `return '已收定位 \\$rx 条';` —— 编译通过、参数却永远显示不出来。
    """
    ps = _params(key)
    if not ps:
        return ['  @override',
                "  String get %s => '%s';" % (key, esc(text))]
    return ['  @override',
            '  String %s(%s) {' % (key, ', '.join('String ' + x for x in ps)),
            "    return '%s';" % interp(key, esc(text)),
            '  }']


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

    # ── ①b 占位符的 @元数据（**只**写在模板 arb 里）──
    #
    # gen-l10n 从模板 arb 的 `@key` 块读占位符类型。只把 `{rx}` 写在文案里
    # 而不给元数据，它会按 Object 生成参数 —— 与这里手写的 `String rx` 不一致，
    # 本机（不重新生成产物）与 CI（重新生成）看到的是两份不同的签名。
    p = os.path.join(ROOT, 'lib', 'l10n', 'app_zh.arb')
    t = read(p, newline='')
    add = []
    for k in KEYS:
        ps = _params(k)
        if not ps or '"@%s":' % k in t:
            continue
        meta = {'placeholders': {x: {'type': PLACEHOLDERS[k][x]} for x in ps}}
        add.append('  %s: %s'
                   % (json.dumps('@' + k, ensure_ascii=False),
                      json.dumps(meta, ensure_ascii=False,
                                 indent=2).replace('\n', '\n  ')))
    if add:
        write(p, add_lines(t, add), newline='')
    try:
        json.loads(read(p))
    except Exception as e:
        print('app_zh.arb 的 @元数据拼坏了: %s' % e)
        return 1
    print('%-22s @元数据 +%d' % ('app_zh.arb', len(add)))

    # ── ② 抽象类 ──
    p = os.path.join(ROOT, 'lib', 'l10n', 'app_localizations.dart')
    s = read(p)
    code = []
    for k, v in KEYS.items():
        if re.search(r'String (?:get )?%s\b' % k, s):
            continue
        code.append("  /// 外接 GPS 模块（蓝牙 SPP / NMEA 0183）。\n  ///\n"
                    "  /// In zh, this message translates to:\n  /// **'%s'**\n"
                    "  String %s;\n" % (v[0], member(k)))
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
                add += [''] + members(k, KEYS[k][LANGS.index(lg)])
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
