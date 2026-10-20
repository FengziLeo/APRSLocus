#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""官网最低版本文件（`docs/assets/min_version.json`）的静态检查。

## 为什么需要它

这份文件是**手写的一份 JSON**，而它在应用里的作用是"低于这个版本就不让用"。
写坏的后果都**不报错**，只是"闸门不按你想的那样落下来"：

  * 版本号写成 `2.1,20` / `2.x` / `v2` → 应用里比较判不出来 → **不拦**（漏拦）；
  * 版本号写成**还没发布的版本**（比如现在就写 `2.2.0`）→ 把**所有用户**（包括
    刚装上最新版的人）一起挡在门外，而且没有自救按钮；
  * JSON 语法坏掉 / 字段名拼错（`minversion`）→ 应用侧解析成"不设下限" → **不拦**；
  * 文件路径改了而应用没改（或反过来）→ 取不到 → 永远不拦。

所以钉在这里：格式、日期、以及"应用到底从哪里取这份文件"一起核对。
注意 `minVersion` **允许为空**（空 = 不设下限，这是默认状态），空不是错。

用法：python3 tool/check_min_version.py
退出码 0 = 一致；1 = 有问题（列出具体哪一条）。
"""
import io
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JSON_PATH = os.path.join(ROOT, 'docs', 'assets', 'min_version.json')
APP = os.path.join(ROOT, 'lib', 'min_version.dart')
STATE = os.path.join(ROOT, 'lib', 'state.dart')

RE_DATE = re.compile(r'^\d{4}-\d{2}-\d{2}$')
# 与 lib/version_compare.dart 能读的形状一致：可带前导 v，点或下划线分段，段是数字。
RE_VER = re.compile(r'^[vV]?\d+(?:[._]\d+)*$')


def _parts(v):
    """把版本号切成可比较的数字段（比较规则只需要数字段）。"""
    out = []
    for p in re.split(r'[._-]', v.replace('v', '').replace('V', '')):
        out.append(int(p) if p.isdigit() else -1)
    return out


def _cmp(a, b):
    pa, pb = _parts(a), _parts(b)
    n = max(len(pa), len(pb))
    pa += [0] * (n - len(pa))
    pb += [0] * (n - len(pb))
    return (pa > pb) - (pa < pb)


def app_version():
    """从 lib/state.dart 读当前版本号（唯一真源，tool/sync_version.py 写它）。"""
    try:
        src = io.open(STATE, encoding='utf-8').read()
    except Exception:
        return ''
    m = re.search(r"static const appVersion = '([^']+)'", src)
    return m.group(1) if m else ''


def main() -> int:
    errors = []
    warnings = []

    if not os.path.exists(JSON_PATH):
        print('缺 docs/assets/min_version.json（应用要从这里取最低版本）')
        return 1
    text = io.open(JSON_PATH, encoding='utf-8').read()
    try:
        data = json.loads(text)
    except Exception as e:
        print('min_version.json 不是合法 JSON：%s' % e)
        print('  ⚠ 应用侧会当成"没设下限" —— 闸门永远不落下，而且不会有任何提示')
        return 1
    if not isinstance(data, dict):
        print('min_version.json 顶层必须是对象')
        return 1

    if not RE_DATE.match(str(data.get('updated', ''))):
        errors.append('`updated` 必须是 YYYY-MM-DD（现在是 %r）' % data.get('updated'))

    if 'minVersion' not in data:
        errors.append('缺 `minVersion` 字段（不设下限也要显式写空串，'
                      '否则等于拼错字段名时永远不知道）')
        mv = ''
    else:
        mv = data.get('minVersion')
        if not isinstance(mv, str):
            errors.append('`minVersion` 必须是字符串（现在是 %r）' % (mv,))
            mv = ''

    mv = mv.strip()
    if mv:
        if not RE_VER.match(mv):
            errors.append('`minVersion`=%r 不是能比较的版本号（允许 `2.1.20` / `v2.1` / `2_1_3`）'
                          '—— 应用比较时判不出来，会**静默不拦**' % (mv,))
        else:
            cur = app_version()
            if cur and _cmp(mv, cur) > 0:
                errors.append('`minVersion`=%s **高于**当前版本 %s —— 这一发下去会把'
                              '刚装上最新版的用户也一起挡在门外（还没发布写不得）'
                              % (mv, cur))
            elif cur:
                warnings.append('最低版本 %s，当前发布 %s（旧版会被拦是预期的，'
                                '记得这是**本人可用的最低版本**）' % (mv, cur))

    if 'reason' in data and not isinstance(data.get('reason'), str):
        errors.append('`reason` 必须是字符串（会原样显示在拦截页上）')

    # 应用必须从这份文件取（路径写错 = 取不到，而应用只会"静默放行"）
    if not os.path.exists(APP):
        errors.append('缺 lib/min_version.dart')
    else:
        app = io.open(APP, encoding='utf-8').read()
        if 'assets/min_version.json' not in app:
            errors.append('lib/min_version.dart 里找不到 `assets/min_version.json` —— '
                          '应用取的地址与这份文件不一致')
        if '失败放行' not in app:
            errors.append('lib/min_version.dart 里没有"失败放行"的说明 —— '
                          '这条是安全底线（拉不到时不让人用，等于一次网络抖动封掉全体现有用户）')

    if warnings:
        for w in warnings:
            print('提示：', w)
    if errors:
        print('最低版本检查失败：')
        for e in errors:
            print('  -', e)
        return 1
    print('最低版本 ok（minVersion=%s；格式与应用的取址一致）' % (mv or '空（不设下限）'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
