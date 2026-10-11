#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""智能体授权名单（`docs/assets/agent_allow.json`）的静态检查。

## 为什么需要它

智能体**不对普通用户开放**，这份白名单就是那把锁。与限制名单（黑名单）对称，
但方向相反、后果也相反：

  * 黑名单写坏 → 应用侧"失败放行"，顶多是**没拦住**（不影响正常用户）；
  * 白名单写坏 → 应用侧"默认拒绝"，写错的后果是**授权过的人被挡在门外**，
    或者反过来 —— `call` 手滑写成 `*` 就把智能体对**所有人**开放。

所以这里钉死三件在应用里**都不会报错、只会静默生效**的事：

  1. JSON / 结构合法，`updated` 是日期，`entries` 是数组；
  2. 每条 `call` 合法（大写、可带 -SSID、可含 `*`），且**至少有一个非通配符
     字符** —— 只写 `*` 或 `-*` 等于"授权所有人"，应用会作废这条；
  3. 应用到底从哪取这份文件（路径改了而这里没改 = 取不到 → 所有人被拒）。

用法：python3 tool/check_agent_allow.py
退出码 0 = 一致；1 = 有问题（列出具体哪一条）。
"""
import io
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JSON_PATH = os.path.join(ROOT, 'docs', 'assets', 'agent_allow.json')
APP = os.path.join(ROOT, 'lib', 'agent_allow.dart')

RE_CALL = re.compile(r'^[A-Z0-9*-]{1,16}$')
RE_HAS_ALNUM = re.compile(r'[A-Z0-9]')
RE_DATE = re.compile(r'^\d{4}-\d{2}-\d{2}$')


def main() -> int:
    errors = []

    if not os.path.exists(JSON_PATH):
        print('缺 docs/assets/agent_allow.json（应用要从这里取授权名单）')
        return 1
    text = io.open(JSON_PATH, encoding='utf-8').read()
    try:
        data = json.loads(text)
    except Exception as e:
        print('agent_allow.json 不是合法 JSON：%s' % e)
        print('  ⚠ 应用侧会判为「未知」→ 名单拉不到 = 默认拒绝（授权过的人也会被挡）')
        return 1
    if not isinstance(data, dict):
        print('agent_allow.json 顶层必须是对象')
        return 1

    if not RE_DATE.match(str(data.get('updated', ''))):
        errors.append('`updated` 必须是 YYYY-MM-DD（现在是 %r）' % data.get('updated'))
    entries = data.get('entries')
    if not isinstance(entries, list):
        errors.append('`entries` 必须是数组')
        entries = []

    seen = {}
    for i, e in enumerate(entries):
        where = 'entries[%d]' % i
        if not isinstance(e, dict):
            errors.append('%s 必须是对象' % where)
            continue
        call = e.get('call')
        if not call:
            errors.append('%s 没有 call —— 白名单条目**必须有呼号**，否则永远不会授权' % where)
            continue
        c = str(call)
        if not RE_CALL.match(c):
            errors.append('%s 的 call=%r 不合法（大写字母数字、可带 -SSID、可含 `*`；'
                          '小写或带空格在应用里会**静默不命中**）' % (where, call))
        elif not RE_HAS_ALNUM.search(c):
            errors.append('%s 的 call=%r 里一个字母数字都没有 —— 那等于"授权所有人"，'
                          '应用会**作废**这条（防手滑把智能体对所有人开放）' % (where, call))
        elif c in seen:
            errors.append('%s 的 call=%s 与 %s 重复' % (where, call, seen[c]))
        else:
            seen[c] = where
        if 'at' in e and not RE_DATE.match(str(e.get('at'))):
            errors.append('%s 的 at=%r 不是 YYYY-MM-DD' % (where, e.get('at')))

    # 应用必须从这份文件取，且必须显式写出"默认拒绝"这条安全底线
    if not os.path.exists(APP):
        errors.append('缺 lib/agent_allow.dart')
    else:
        app = io.open(APP, encoding='utf-8').read()
        if 'assets/agent_allow.json' not in app:
            errors.append('lib/agent_allow.dart 里找不到 `assets/agent_allow.json` —— '
                          '应用取的地址与这份文件不一致')
        if '默认拒绝' not in app:
            errors.append('lib/agent_allow.dart 里没有"默认拒绝"的说明 —— '
                          '这条是安全底线（拉不到名单时绝不能自动放行）')
        if 'mc081208@163.com' not in app:
            errors.append('lib/agent_allow.dart 里没有申请邮箱 mc081208@163.com —— '
                          '授权页拿不到投递地址')

    if errors:
        print('智能体授权名单检查失败：')
        for e in errors:
            print('  -', e)
        return 1
    print('智能体授权名单 ok（%d 条；格式与应用的取址一致）' % len(entries))
    return 0


if __name__ == '__main__':
    sys.exit(main())
