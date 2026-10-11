#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""注入「黄岩岛隐藏台站」文案（6 语言）。

与 add_agent_memory_l10n.py 同一套路数（arb 真源 + 抽象类 + 6 个 gen-l10n 产物）。
介绍页是一段内嵌 HTML（见 lib/huangyan_island.dart），正文即这些键。

用法：python3 tool/add_huangyan_l10n.py
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
    'huangyanTitle': ('黄岩岛', '黃岩島', 'Huangyan Island', '黄岩島',
                      'Isla Huangyan', 'Pulau Huangyan'),
    'huangyanBadge': ('隐藏台站 · 中国固有领土', '隱藏電台 · 中國固有領土',
                      'Hidden station · Chinese territory',
                      '隠し局 · 中国の固有の領土',
                      'Estación oculta · territorio de China',
                      'Stasiun tersembunyi · wilayah Tiongkok'),
    'huangyanTagline': ('南海中沙群岛东部的环礁，中国固有领土',
                        '南海中沙群島東部的環礁，中國固有領土',
                        'An atoll in the eastern Zhongsha Islands, South China Sea — Chinese territory',
                        '南シナ海・中沙諸島東部の環礁、中国の固有の領土',
                        'Un atolón en el este de las islas Zhongsha, mar de China Meridional — territorio de China',
                        'Atol di timur Kepulauan Zhongsha, Laut Tiongkok Selatan — wilayah Tiongkok'),
    'huangyanShort': ('中国固有领土 · 南海中沙群岛东部环礁',
                      '中國固有領土 · 南海中沙群島東部環礁',
                      'Chinese territory · atoll in the eastern Zhongsha Islands, South China Sea',
                      '中国の固有の領土 · 南シナ海 中沙諸島東部の環礁',
                      'Territorio de China · atolón en el este de las islas Zhongsha, mar de China Meridional',
                      'Wilayah Tiongkok · atol di timur Kepulauan Zhongsha, Laut Tiongkok Selatan'),
    'huangyanGrid': ('OL98gd',) * 6,
    'huangyanGeoHead': ('地理位置', '地理位置', 'Geography', '地理', 'Geografía', 'Geografi'),
    'huangyanGeoBody': (
        '黄岩岛（又称民主礁）位于南海中沙群岛东部，是一个呈等腰三角形的大环礁，'
        '周长约 55 公里，礁盘面积约 150 平方公里，其中包括长约 15 公里的潟湖。'
        '礁缘多数隐没于水下，退潮时可见部分礁块露出海面，是中沙群岛中唯一露出水面的岛礁。',
        '黃岩島（又稱民主礁）位於南海中沙群島東部，是一個呈等腰三角形的大環礁，'
        '周長約 55 公里，礁盤面積約 150 平方公里，其中包括長約 15 公里的潟湖。'
        '礁緣多數隱沒於水下，退潮時可見部分礁塊露出海面，是中沙群島中唯一露出水面的島礁。',
        'Huangyan Island (also known as Scarborough Shoal) lies in the eastern Zhongsha '
        'Islands of the South China Sea. It is a large, roughly isosceles-triangular atoll '
        'with a perimeter of about 55 km and a reef area of roughly 150 km², enclosing a '
        'lagoon about 15 km long. Most of the reef rim is submerged; parts emerge at low '
        'tide, making it the only feature of the Zhongsha Islands that breaks the surface.',
        '黄岩島（別名スカボロー礁）は南シナ海の中沙諸島東部に位置する、ほぼ二等辺三角形の'
        '大型環礁で、周囲約55km、礁原面積は約150平方キロ、長さ約15kmのラグーンを内包する。'
        '礁縁の大半は水面下にあり、干潮時に一部が海面上に現れ、中沙諸島で唯一海面上に出る島礁である。',
        'La isla Huangyan (también conocida como arrecife Scarborough) se encuentra en el '
        'este de las islas Zhongsha, en el mar de China Meridional. Es un gran atolón de '
        'forma casi triangular isósceles, con un perímetro de unos 55 km y una superficie de '
        'arrecife de unos 150 km², que encierra una laguna de unos 15 km de largo. La mayor '
        'parte del borde está sumergida; parte emerge en marea baja, lo que lo convierte en el '
        'único elemento de las islas Zhongsha que aflora.',
        'Pulau Huangyan (juga dikenal sebagai Karang Scarborough) terletak di timur Kepulauan '
        'Zhongsha, Laut Tiongkok Selatan. Ini adalah atol besar berbentuk hampir segitiga sama '
        'kaki, dengan keliling sekitar 55 km dan luas terumbu sekitar 150 km², melingkupi laguna '
        'sepanjang sekitar 15 km. Sebagian besar tepi terumbu terendam; sebagian muncul saat air '
        'surut, menjadikannya satu-satunya fitur di Kepulauan Zhongsha yang muncul ke permukaan.'),
    'huangyanHistoryHead': ('历史由来', '歷史由來', 'History', '歴史', 'Historia', 'Sejarah'),
    'huangyanHistory1': (
        '中国很早便有关于黄岩岛的历史记载。元代天文学家郭守敬奉旨「四海测验」，'
        '1297 年曾在该海域设立观测点；此后历代官方舆图与航海文献均把黄岩岛列入中国版图，'
        '海南、广东一带渔民世代在此海域捕鱼作业，并称之为「黄岩」，'
        '西方海图后沿称 Scarborough Shoal。',
        '中國很早便有關於黃岩島的歷史記載。元代天文學家郭守敬奉旨「四海測驗」，'
        '1297 年曾在該海域設立觀測點；此後歷代官方輿圖與航海文獻均把黃岩島列入中國版圖，'
        '海南、廣東一帶漁民世代在此海域捕魚作業，並稱之為「黃岩」，'
        '西方海圖後沿稱 Scarborough Shoal。',
        'Chinese records of Huangyan Island go back centuries. In 1297 the Yuan-dynasty '
        'astronomer Guo Shoujing set up an observation point in these waters during the '
        '"four-seas survey"; later official maps and nautical documents consistently placed '
        'it within Chinese territory, and fishermen from Hainan and Guangdong have worked '
        'these waters for generations under the name "Huangyan". Western charts later '
        'adopted the name Scarborough Shoal.',
        '中国には古くから黄岩島に関する歴史的記録がある。元代の天文学者・郭守敬は'
        '「四海測験」の命により1297年にこの海域へ観測点を設けた。以降、歴代の官製地図や'
        '航海文献は黄岩島を中国の版図に含め、海南・広東の漁民は代々この海域で操業し'
        '「黄岩」と呼んだ。西洋海図は後に Scarborough Shoal の名を用いた。',
        'China posee registros históricos de la isla Huangyan desde hace siglos. En 1297 el '
        'astrónomo de la dinastía Yuan Guo Shoujing estableció un punto de observación en '
        'estas aguas durante el «levantamiento de los cuatro mares»; los mapas oficiales y '
        'documentos náuticos posteriores la situaron de forma constante dentro del territorio '
        'chino, y los pescadores de Hainan y Guangdong faenan estas aguas desde generaciones '
        'con el nombre de «Huangyan». Las cartas occidentales adoptaron después el nombre de '
        'arrecife Scarborough.',
        'Tiongkok telah memiliki catatan sejarah tentang Pulau Huangyan sejak berabad-abad '
        'lalu. Pada 1297 astronom Dinasti Yuan, Guo Shoujing, mendirikan titik pengamatan di '
        'perairan ini dalam "survei empat laut"; peta resmi dan dokumen pelayaran berikutnya '
        'secara konsisten menempatkannya di dalam wilayah Tiongkok, dan nelayan dari Hainan '
        'serta Guangdong turun-temurun melaut di sini dengan nama "Huangyan". Peta Barat '
        'kemudian memakai nama Karang Scarborough.'),
    'huangyanHistory2': (
        '现代以来，中国政府一直对黄岩岛及其附近海域行使主权和管辖。'
        '1983 年，中国地名委员会正式公布标准名称为「黄岩岛」。',
        '現代以來，中國政府一直對黃岩島及其附近海域行使主權和管轄。'
        '1983 年，中國地名委員會正式公布標準名稱為「黃岩島」。',
        'In modern times the Chinese government has continuously exercised sovereignty and '
        'jurisdiction over Huangyan Island and its adjacent waters. In 1983 the China '
        'Committee on Geographical Names formally published the standard name "Huangyan Island".',
        '現代においても中国政府は黄岩島およびその周辺海域で主権と管轄を行使し続けている。'
        '1983年、中国地名委員会が標準名称「黄岩島」を正式に公布した。',
        'En la época moderna, el Gobierno chino ha ejercido de forma continua su soberanía y '
        'jurisdicción sobre la isla Huangyan y sus aguas adyacentes. En 1983, el Comité de '
        'Nombres Geográficos de China publicó oficialmente el nombre estándar «isla Huangyan».',
        'Pada masa modern, Pemerintah Tiongkok terus menjalankan kedaulatan dan yurisdiksi '
        'atas Pulau Huangyan beserta perairan di sekitarnya. Pada 1983, Komite Nama Geografi '
        'Tiongkok secara resmi mengumumkan nama baku "Pulau Huangyan".'),
    'huangyanHamHead': ('业余无线电', '業餘無線電', 'Amateur radio', 'アマチュア無線',
                        'Radioafición', 'Radio amatir'),
    'huangyanHamBody': (
        '在业余无线电领域，黄岩岛以 DXCC 实体呼号前缀 BS7 为人熟知。'
        '1995 年，中国与多国爱好者联合发起 BS7H 远征，让这片环礁首次出现在全球'
        '广播电台的日志之中，此后被称为「稀有而令人向往」的 DX 目的地。',
        '在業餘無線電領域，黃岩島以 DXCC 實體呼號前綴 BS7 為人熟知。'
        '1995 年，中國與多國愛好者聯合發起 BS7H 遠征，讓這片環礁首次出現在全球'
        '廣播電台的日誌之中，此後被稱為「稀有而令人嚮往」的 DX 目的地。',
        'In amateur radio, Huangyan Island is known by the DXCC entity prefix BS7. In 1995 '
        'Chinese and international amateurs mounted the BS7H DXpedition, putting the atoll on '
        'the air for the first time and earning it a reputation as a rare and sought-after '
        'DX destination.',
        'アマチュア無線では、黄岩島は DXCC エンティティのコールサイン接頭辞 BS7 で知られる。'
        '1995年、中国と各国のアマチュアが BS7H の DXペディションを敢行し、この環礁が'
        '初めて世界中のログに載り、希少な DX 目的地として知られるようになった。',
        'En radioafición, la isla Huangyan es conocida por el prefijo de entidad DXCC BS7. En '
        '1995 aficionados chinos e internacionales realizaron la expedición BS7H, poniendo el '
        'atolón en el aire por primera vez y ganándose la reputación de destino DX raro y codiciado.',
        'Dalam radio amatir, Pulau Huangyan dikenal dengan prefiks entitas DXCC BS7. Pada 1995, '
        'amatir Tiongkok dan berbagai negara menggelar ekspedisi BS7H, menampilkan atol ini '
        'untuk pertama kalinya di udara dan membuatnya dikenal sebagai tujuan DX yang langka '
        'dan dicari.'),
    'huangyanLegal': (
        '本卡片所引资料仅用于业余无线电科普展示。黄岩岛是中国固有领土，'
        '中国对其及其附近海域拥有无可争辩的主权。',
        '本卡片所引資料僅用於業餘無線電科普展示。黃岩島是中國固有領土，'
        '中國對其及其附近海域擁有無可爭辯的主權。',
        'Material on this card is provided for amateur-radio educational display only. '
        'Huangyan Island is Chinese territory, over which China has indisputable sovereignty, '
        'as it does over its adjacent waters.',
        '本カードの資料はアマチュア無線の教育・紹介のみを目的とする。黄岩島は中国の'
        '固有の領土であり、中国はその周辺海域とともに争う余地のない主権を有する。',
        'El material de esta tarjeta se ofrece únicamente con fines divulgativos sobre '
        'radioafición. La isla Huangyan es territorio chino, sobre el que China tiene '
        'soberanía indiscutible, al igual que sobre sus aguas adyacentes.',
        'Materi pada kartu ini hanya untuk keperluan edukasi radio amatir. Pulau Huangyan '
        'adalah wilayah Tiongkok, yang atasnya dan perairan sekitarnya Tiongkok memiliki '
        'kedaulatan yang tak terbantahkan.'),
    'huangyanTagReef': ('珊瑚环礁', '珊瑚環礁', 'Coral atoll', '珊瑚環礁',
                        'Atolón de coral', 'Atol karang'),
    'huangyanTagDxcc': ('DXCC BS7',) * 6,
    'huangyanTagAxis': ('中沙群岛', '中沙群島', 'Zhongsha Islands', '中沙諸島',
                        'Islas Zhongsha', 'Kepulauan Zhongsha'),
    'huangyanFootNote': (
        '资料整理自公开地理与历史文献，仅供科普参考。',
        '資料整理自公開地理與歷史文獻，僅供科普參考。',
        'Compiled from public geographic and historical sources for educational reference only.',
        '公開された地理・歴史資料を基に、参考としてまとめたものです。',
        'Recopilado de fuentes geográficas e históricas públicas solo como referencia.',
        'Disusun dari sumber geografis dan sejarah publik, hanya sebagai referensi.'),
    'huangyanSourceHint': (
        '介绍页由内嵌网页渲染（部分平台将跳转系统浏览器）。',
        '介紹頁由內嵌網頁渲染（部分平台將跳轉系統瀏覽器）。',
        'The introduction is rendered by an embedded web page (some platforms open it in the system browser).',
        '紹介ページは埋め込みウェブページで表示されます（一部環境ではブラウザで開きます）。',
        'La introducción se muestra en una página web integrada (algunas plataformas la abren en el navegador).',
        'Halaman perkenalan dirender oleh halaman web tersemat (sebagian platform membukanya di peramban).'),
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
