#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""为 issue #35 补一条「电台热点不抢移动数据」的用户提示文案（6 语言）。

背景：连上 IC-705 热点后，若系统把这条无外网的 Wi-Fi 当成默认上网通道，
移动数据会被暂停、APRS-IS 断线。代码层已通过「申请非 INTERNET 的本地 Wi-Fi +
电台套接字按 Wi-Fi IPv4 绑定」解决；这里再给用户一条提示，说明「电台流量走
Wi-Fi、上网走移动数据」，避免他们看到两条网络并存时困惑。

写入约定与 tool/add_link_status_l10n.py 一致：幂等、追加到 ARB 末尾。
⚠ ICU：译文里不要出现落单的半角单引号。
"""
import io
import json
import os
import re

KEYS = {
    'icomLanHotspotRoutingHint': (
        '连上电台热点后，电台数据会绑定到 Wi-Fi 局域网，移动数据仍用于 APRS-IS 上网；'
        '若系统把这条热点当成了默认上网通道，请在该 Wi-Fi 的高级设置里关闭「自动切换网络」。',
        '連上電台熱點後，電台資料會綁定到 Wi-Fi 區域網路，行動數據仍用於 APRS-IS 上網；'
        '若系統把這條熱點當成預設上網通道，請在該 Wi-Fi 的進階設定裡關閉「自動切換網路」。',
        'After joining the radio hotspot, radio traffic is bound to that Wi-Fi LAN while '
        'mobile data stays on APRS-IS. If the system treats the hotspot as the default '
        'internet route, turn off "auto-switch network" in that Wi-Fi\'s advanced settings.',
        '無線機のホットスポットに接続すると、無線機の通信は Wi-Fi に、APRS-IS は'
        'モバイルデータに振り分けられます。システムがこのホットスポットを既定の'
        'インターネット経路にした場合は、その Wi-Fi の詳細設定で「自動ネットワーク'
        '切り替え」をオフにしてください。',
        'Al unirte al punto de acceso de la radio, el tráfico de la radio se ata a esa '
        'Wi-Fi y los datos móviles siguen para APRS-IS. Si el sistema toma el punto de '
        'acceso como ruta de internet predeterminada, desactiva "cambio automático de red" '
        'en los ajustes avanzados de esa Wi-Fi.',
        'Setelah terhubung ke hotspot radio, lalu lintas radio diikat ke Wi-Fi tersebut '
        'sementara data seluler tetap untuk APRS-IS. Jika sistem menjadikan hotspot ini '
        'rute internet default, matikan "ganti jaringan otomatis" di pengaturan lanjutan '
        'Wi-Fi itu.',
    ),
}

LANGS = ['zh', 'zh_TW', 'en', 'ja', 'es', 'id']
IDX = {lg: i for i, lg in enumerate(LANGS)}


def main() -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    arb_dir = os.path.join(root, 'lib', 'l10n')
    for lg in LANGS:
        p = os.path.join(arb_dir, f'app_{lg}.arb')
        src = io.open(p, encoding='utf-8').read()
        add = []
        for key, vals in KEYS.items():
            if re.search(r'^\s*"' + re.escape(key) + r'":', src, re.M):
                print(f'  {lg}/{key}: 已存在，跳过')
                continue
            add.append(f'  {json.dumps(key, ensure_ascii=False)}: '
                       f'{json.dumps(vals[IDX[lg]], ensure_ascii=False)},')
        if not add:
            continue
        i = src.rstrip().rfind('}')
        head = src[:i].rstrip()
        if not head.endswith(','):
            head += ','
        src = head + '\n' + '\n'.join(add).rstrip(',') + '\n' + src[i:]
        io.open(p, 'w', encoding='utf-8').write(src)
        print(f'{lg}: 追加 {len(add)} 行')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
