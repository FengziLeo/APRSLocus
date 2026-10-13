import 'package:flutter_test/flutter_test.dart';

import 'package:aprslocus/agent_stream.dart';

/// 智能体流式（SSE）解析的回归测试。
///
/// 这一层用模拟数据测而不是连真后端：流的坑都在「分片怎么拼」上 ——
/// `tool_calls` 的 id/name/arguments 是**分几片**来的，真实请求里要复现
/// 「半个 JSON 参数被 TCP 切开」几乎只能靠运气。这里把每个已知形状钉死。
void main() {
  String delta(String payload) => 'data: $payload';

  group('sseData', () {
    test('只认 data: 行，其余一律忽略', () {
      expect(sseData(''), isNull);
      expect(sseData('   '), isNull);
      expect(sseData(': keep-alive'), isNull);
      expect(sseData('event: message'), isNull);
      expect(sseData('id: 42'), isNull);
      expect(sseData('data:'), isNull);
      expect(sseData('data: {}'), '{}');
      expect(sseData('data:   {"a":1}  '), '{"a":1}');
      expect(sseData('data: [DONE]'), '[DONE]');
    });
  });

  group('AgentStreamAssembler', () {
    test('正文分片累加，逐字喂也不丢', () {
      final a = AgentStreamAssembler();
      a.feed(delta('{"choices":[{"delta":{"content":"你"}}]}'));
      expect(a.text, '你');
      a.feed(delta('{"choices":[{"delta":{"content":"好"}}]}'));
      expect(a.text, '你好');
      a.feed(delta('{"choices":[{"delta":{"content":"，世界"}}]}'));
      expect(a.text, '你好，世界');
      expect(a.isEmpty, isFalse);
      expect(a.error, isNull);
      expect(a.build().content, '你好，世界');
      expect(a.build().toolCalls, isEmpty);
    });

    test('role 前缀片 / 空 content 片 / [DONE] 都不算内容', () {
      final a = AgentStreamAssembler();
      expect(a.feed(delta('{"choices":[{"delta":{"role":"assistant"}}]}')),
          isFalse);
      expect(a.feed(delta('{"choices":[{"delta":{"content":""}}]}')), isFalse);
      expect(a.feed(delta('{"choices":[{"delta":{"content":null}}]}')), isFalse);
      expect(a.feed(delta('[DONE]')), isFalse);
      expect(a.feed(': ping'), isFalse);
      expect(a.text, '');
    });

    test('tool_calls 分片：id/name 在首片，arguments 逐段拼', () {
      final a = AgentStreamAssembler();
      a.feed(delta('{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1",'
          '"type":"function","function":{"name":"strategy_add_point",'
          '"arguments":""}}]}}]}'));
      a.feed(delta('{"choices":[{"delta":{"tool_calls":[{"index":0,'
          '"function":{"arguments":"{\\"lat\\":31."}}]}}]}'));
      a.feed(delta('{"choices":[{"delta":{"tool_calls":[{"index":0,'
          '"function":{"arguments":"5,\\"lng\\":121.4}"}}]}}]}'));
      final m = a.build();
      expect(m.content, '');
      expect(m.toolCalls, hasLength(1));
      expect(m.toolCalls.first.id, 'call_1');
      expect(m.toolCalls.first.name, 'strategy_add_point');
      expect(m.toolCalls.first.arguments['lat'], 31.5);
      expect(m.toolCalls.first.arguments['lng'], 121.4);
    });

    test('多个 tool_call 交错按 index 归并、输出按 index 排序', () {
      final a = AgentStreamAssembler();
      a.feed(delta('{"choices":[{"delta":{"tool_calls":['
          '{"index":1,"id":"b","function":{"name":"list_strategy","arguments":"{}"}},'
          '{"index":0,"id":"a","function":{"name":"get_app_state","arguments":"{}"}}'
          ']}}]}'));
      final calls = a.build().toolCalls;
      expect(calls.map((c) => c.id).toList(), ['a', 'b']);
      expect(calls.map((c) => c.name).toList(),
          ['get_app_state', 'list_strategy']);
    });

    test('每片都重复带 name 的后端不会把名字拼两遍', () {
      final a = AgentStreamAssembler();
      for (var i = 0; i < 3; i++) {
        a.feed(delta('{"choices":[{"delta":{"tool_calls":[{"index":0,'
            '"function":{"name":"strategy_clear","arguments":"${i == 2 ? "{}" : ""}"}}]}}]}'));
      }
      expect(a.build().toolCalls.first.name, 'strategy_clear');
    });

    test('缺 id 的 tool_call 有稳定占位（否则 tool 结果配不上对）', () {
      final a = AgentStreamAssembler();
      a.feed(delta('{"choices":[{"delta":{"tool_calls":[{"index":0,'
          '"function":{"name":"navigate","arguments":"{}"}}]}}]}'));
      final c = a.build().toolCalls.first;
      expect(c.id, isNotEmpty);
      expect(c.name, 'navigate');
      expect(c.arguments, isEmpty);
    });

    test('服务端流内报错被记下来（不抛，交给上层翻成人话）', () {
      final a = AgentStreamAssembler();
      a.feed(delta('{"error":{"message":"Invalid API key","type":"auth"}}'));
      expect(a.error, 'Invalid API key');
      expect(a.isEmpty, isTrue);
    });

    test('后端忽略 stream:true 时（回一整段普通 JSON）识别为「空流」', () {
      final a = AgentStreamAssembler();
      // 普通响应的 JSON 是多行的 —— 这正是它「一行也解析不出内容」的原因。
      for (final line in const [
        '{"id":"chatcmpl-1",',
        ' "choices":[{"message":{"role":"assistant","content":"hi"}}]}',
      ]) {
        a.feed(line);
      }
      expect(a.isEmpty, isTrue); // 上层据此退回非流式
      expect(a.error, isNull);
    });

    test('用 message 而非 delta 的兼容片也能认', () {
      final a = AgentStreamAssembler();
      a.feed(delta('{"choices":[{"message":{"content":"ok"}}]}'));
      expect(a.text, 'ok');
    });
  });
}
