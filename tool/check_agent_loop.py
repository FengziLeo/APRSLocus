#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""智能体「对话循环」的三条安全线（`lib/agent.dart`）静态检查。

这三件事在应用里**都不会编译报错、也不会 analyze 报错**，坏了只有在真机上
用起来才看得见，而且症状都容易被误解成「模型不行 / 网络不行」：

  1. **流式请求必须带 `stream: true`。**
     不带的话后端按普通请求回一整段 JSON，流里一个 `data:` 分片都没有，解析器
     判定「没拿到流」→ 退回整段式**再发一次同样的请求**：每轮白等一倍时间、
     白花一倍 token（用户感受到的就是「回复过慢」），而「逐字」只剩一层假动画。
     非流式那条路退回时用的 body 不该带 `stream`（带了会回 SSE，那边解析不了）。

  2. **单个工具抛异常不得带走整轮对话。**
     没有局部 try/catch 时，工具内部一个畸形参数 / 偶发异常会直接冒到
     [AgentService.send] 的外层 catch —— 用户看到的是「调了工具之后突然没了
     下文」。正确做法是把异常变成**这次调用的结果**（`ERROR: …`）回给模型，
     同时保住 assistant.tool_calls ↔ tool 消息的配对。

  3. **轮次用尽 / 模型只回空串时必须有收尾。**
     以前 `for (round < maxToolRounds)` 走完就直接进 finally：历史最后一条还是
     「我在调工具」，界面上就是干停住（「调几次工具就断掉了」）。现在循环后必须
     有一次**不带工具**的收尾请求，且上层必须传 l10n 兜底文案。

用法：python3 tool/check_agent_loop.py
退出码 0 = 三条都在；1 = 有缺失（列出具体缺哪条）。
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENT = os.path.join(ROOT, 'lib', 'agent.dart')
UI = os.path.join(ROOT, 'lib', 'agent_ui.dart')
ARB = os.path.join(ROOT, 'lib', 'l10n', 'app_zh.arb')
LANGS = ['zh', 'zh_TW', 'en', 'ja', 'es', 'id']

KEY = 'agentNoFinalAnswer'


def _fn_body(src, header):
    """取某个函数（或构造块）从 header 起到下一个顶格 `}` 的文本。"""
    i = src.find(header)
    if i < 0:
        return ''
    j = src.find('\n  }', i)
    return src[i:j if j > 0 else len(src)]


def main() -> int:
    errors = []
    for p in (AGENT, UI):
        if not os.path.exists(p):
            print('缺文件：%s' % p)
            return 1
    src = io.open(AGENT, encoding='utf-8').read()
    ui = io.open(UI, encoding='utf-8').read()

    # ── 1. 流式请求带 stream: true ──────────────────────────────────────
    chat = _fn_body(src, 'Future<AgentMessage> _chat(')
    if not chat:
        errors.append('找不到 AgentService._chat（函数名/签名改了？）')
    else:
        if "'stream': true" not in chat:
            errors.append('_chat 里没有 `\'stream\': true` —— 流式请求会被后端当成'
                          '普通请求，每轮白白多发一次同样的请求（回复变慢一倍）')
        if '_chatStreaming(' not in chat:
            errors.append('_chat 里没有调用 _chatStreaming（逐字回复整条路没了？）')
        if 'jsonEncode({' not in chat:
            errors.append('_chat 没有为流式单独拼 body —— 别把带 stream 的 body 也'
                          '拿去走 _chatOnce（SSE 那边解析不了）')

    # ── 2. 工具异常局部兜底 ─────────────────────────────────────────────
    if 'result = \'ERROR: $e\';' not in src:
        errors.append("工具执行处没有局部 catch（应把异常变成这次调用的结果 "
                      "`ERROR: $e`）—— 单个工具出问题会带走整轮对话")
    else:
        # 必须包在「执行工具」那一段里，别只是别处碰巧有一句
        i = src.find('await execute(')
        seg = src[max(0, i - 200): i + 1200] if i > 0 else ''
        if 'await execute(' not in seg or 'catch' not in seg:
            errors.append('`ERROR: $e` 不在工具执行的分支里（包错地方等于没包）')

    # ── 3. 轮次用尽要收尾 ──────────────────────────────────────────────
    if 'for (var round = 0; round < maxToolRounds; round++)' not in src:
        errors.append('找不到 maxToolRounds 的轮次循环（改结构了？这里要同步改）')
    if '_chat(const [])' not in src:
        errors.append('循环之后没有「不带工具」的收尾请求（`_chat(const [])`）—— '
                      '轮次用完会直接停在最后一个工具气泡上（看起来像断了）')
    if 'noFinalAnswerText' not in src:
        errors.append('send 没有 noFinalAnswerText 兜底文案参数')
    if 'noFinalAnswerText: s.agentNoFinalAnswer' not in ui:
        errors.append('lib/agent_ui.dart 没把 s.agentNoFinalAnswer 传给 send '
                      '（兜底文案会是空的）')

    text = io.open(ARB, encoding='utf-8').read() if os.path.exists(ARB) else ''
    if '"%s"' % KEY not in text:
        errors.append('app_zh.arb 里没有 %s（跑 python3 tool/add_agent_v4_l10n.py）' % KEY)
    for lg in LANGS:
        p = os.path.join(ROOT, 'lib', 'l10n', 'app_%s.arb' % lg)
        if not os.path.exists(p):
            continue
        if '"%s"' % KEY not in io.open(p, encoding='utf-8').read():
            errors.append('app_%s.arb 里没有 %s（6 语言都要有）' % (lg, KEY))

    if errors:
        print('智能体对话循环检查失败：')
        for e in errors:
            print('  -', e)
        return 1
    print('智能体对话循环 ok（流式带 stream:true · 工具异常局部兜底 · 轮次用尽有收尾）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
