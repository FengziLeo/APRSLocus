/// ─── 智能体「逐字回复」的 SSE 增量拼装 ───
///
/// 单独一个文件、**纯逻辑**（只依赖 `dart:convert`）是有意的：流式解析的坑
/// 全在细节里，接网线调不出来 ——
///
/// * 一次 delta 可能只带半个 `tool_call`（`function.arguments` 是**逐段**下发的
///   JSON 字符串，一段可能是 `{"ci` ），必须按 `index` 归并、按序拼接；
/// * 首个分片才带 `id` 与 `function.name`，后续分片这两个字段缺失或为空串；
/// * 心跳 / 注释行（以 `:` 开头）、空行、`data: [DONE]` 都不是内容；
/// * 有的兼容后端**忽略** `stream:true`，直接回一整段普通 JSON —— 那不是一个
///   合法的 SSE 流，解析出来会是「空回复」，上层必须能识别并退回非流式。
///
/// 所以把它做成可以喂字符串的纯函数 + 一个累加器，用模拟数据钉死
/// （见 `test/agent_stream_test.dart`）。本文件不认识 HttpClient，也不知道 UI。
library;

import 'dart:convert';

import 'agent.dart' show AgentMessage, AgentToolCall;

/// 从一行 SSE 里取出 `data:` 负载。
///
/// 返回 null 表示这行**不含**数据（空行、`:` 心跳、`event:`/`id:` 等字段），
/// 返回 `[DONE]` 表示流正常结束（OpenAI 的收尾标记）。
String? sseData(String line) {
  final t = line.trim();
  if (t.isEmpty || t.startsWith(':')) return null;
  if (!t.startsWith('data:')) return null;
  final v = t.substring(5).trim();
  return v.isEmpty ? null : v;
}

/// 把一个流式响应拼成**与非流式完全同形**的一条助手消息。
class AgentStreamAssembler {
  final StringBuffer _text = StringBuffer();
  final Map<int, _ToolPart> _tools = {};

  /// 服务端在流里报的错（OpenAI 允许用一条 `data: {"error":…}` 收尾）
  String? error;

  /// 到目前为止收到的正文 —— UI 就渲染它，「逐字」是这么来的。
  String get text => _text.toString();

  /// 一个字节的内容都没收到（用来判断「后端忽略了 stream:true」）。
  bool get isEmpty => _text.isEmpty && _tools.isEmpty;

  /// 喂一行。返回 true 表示**正文变长了**（UI 需要重绘）。
  ///
  /// 参数组装不会返回 true：那是工具调用的增量，界面上有别的指示器。
  bool feed(String line) {
    final payload = sseData(line);
    if (payload == null || payload == '[DONE]') return false;
    Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      return false; // 半截 JSON / 非 JSON 的心跳，忽略
    }
    if (decoded is! Map) return false;
    final err = decoded['error'];
    if (err != null) {
      error = err is Map ? '${err['message'] ?? err}' : '$err';
      return false;
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return false;
    final first = choices.first;
    if (first is! Map) return false;
    // 标准流式用 `delta`；少数后端（或最后一片）给完整 `message`，一并认。
    final block = first['delta'] is Map
        ? first['delta'] as Map
        : (first['message'] is Map ? first['message'] as Map : null);
    if (block == null) return false;
    var grew = false;
    final c = block['content'];
    if (c is String && c.isNotEmpty) {
      _text.write(c);
      grew = true;
    }
    final tcs = block['tool_calls'];
    if (tcs is List) {
      for (final raw in tcs) {
        if (raw is! Map) continue;
        final i = int.tryParse('${raw['index']}') ?? _tools.length;
        (_tools[i] ??= _ToolPart()).add(raw);
      }
    }
    return grew;
  }

  /// 结束：产出助手消息（内容 + 工具调用）。
  AgentMessage build() => AgentMessage(
        role: 'assistant',
        content: _text.toString(),
        toolCalls: [
          for (final i in _tools.keys.toList()..sort()) _tools[i]!.toCall(),
        ],
      );
}

/// 一个 `tool_call` 的增量片（靠 `index` 对齐）
class _ToolPart {
  String id = '';
  final StringBuffer name = StringBuffer();
  final StringBuffer args = StringBuffer();

  void add(Map raw) {
    if (id.isEmpty) {
      final v = raw['id'];
      if (v is String && v.isNotEmpty) id = v;
    }
    final fn = raw['function'];
    if (fn is! Map) return;
    final n = fn['name'];
    // name 一般只在首片出现；重复给同名（有些后端每片都带）也不能拼成
    // `strategy_add_pointstrategy_add_point` —— 只收「当前还没收到过」的那次。
    if (n is String && n.isNotEmpty && name.isEmpty) name.write(n);
    final a = fn['arguments'];
    if (a is String) args.write(a);
  }

  AgentToolCall toCall() => AgentToolCall.fromJson({
        // 没给 id 的后端（少见）：造一个稳定的占位，否则 tool 结果消息
        // 无法与 assistant 的 tool_calls 配对，下一轮请求会被服务端打回。
        'id': id.isEmpty ? 'call_${name}_${args.length}' : id,
        'function': {'name': name.toString(), 'arguments': args.toString()},
      });
}
