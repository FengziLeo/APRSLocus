import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aprslocus/agent.dart';
import 'package:aprslocus/agent_tools.dart';
import 'package:aprslocus/models.dart';
import 'package:aprslocus/state.dart';

/// 智能体「工具层」的回归测试。
///
/// 这一层是**模型与 AppState 之间唯一的写入通道**：模型说了改设置、发消息，
/// 真正落地的就是这里。几类错误在 analyze / 编译下全绿，只有真机点到才发现，
/// 所以在这里钉死：
/// - 权限闸门（没授权不许发消息 / 不许改设置）；
/// - 参数校验（越界值必须被拒，而不是静默写进 state）；
/// - 参数类型（字符串 "30" 与 int 30 都应接受）；
/// - `_val` 的 null 归一（没传的字段不能变成字符串 "null"）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AgentToolOutcome> run(
    AppState st,
    String name,
    Map<String, dynamic> args, {
    bool allowSend = true,
    bool allowSettings = true,
    bool allowTasks = false,
  }) =>
      executeAgentTool(st, name, args,
          allowedSend: allowSend,
          allowedSettings: allowSettings,
          allowedTasks: allowTasks);

  group('schema', () {
    test('未授权发送时，send_* 工具不出现在 schema 里', () {
      final names = agentToolSchemas(allowSend: false)
          .map((t) => t['function']['name'])
          .toSet();
      expect(names.any((n) => '$n'.startsWith('send_')), isFalse);
      // 只读工具仍在
      expect(names, contains('get_app_state'));

      final withSend = agentToolSchemas(allowSend: true)
          .map((t) => t['function']['name'])
          .toSet();
      expect(withSend, contains('send_message'));
      expect(withSend, contains('send_beacon_now'));
    });
  });

  group('权限闸门', () {
    test('未授权发送：send_message 被拒且不产生消息', () async {
      final st = AppState();
      final before = st.messages.length;
      final r = await run(st, 'send_message', {'to': 'BG7LZQ', 'text': 'hi'},
          allowSend: false);
      expect(r.text, contains('Permission denied'));
      expect(st.messages.length, before);
    });

    test('未授权改设置：set_preferences 被拒且值不变', () async {
      final st = AppState();
      final before = st.darkMode;
      final r = await run(st, 'set_preferences', {'dark_mode': !before},
          allowSettings: false);
      expect(r.text, contains('Permission denied'));
      expect(st.darkMode, before);
    });

    test('navigate 不受「改设置」开关限制（只切页面）', () async {
      final st = AppState();
      final r = await run(st, 'navigate', {'screen': 'map'},
          allowSettings: false);
      expect(r.text, isNot(contains('Permission denied')));
    });
  });

  group('参数校验', () {
    test('非法枚举值被拒、状态不变', () async {
      final st = AppState();
      final before = st.mapType;
      final r = await run(st, 'set_preferences', {'map_type': 'no-such-map'});
      expect(r.text, contains('ERROR'));
      expect(st.mapType, before);
    });

    test('越界的 ui_scale 被拒', () async {
      final st = AppState();
      final before = st.uiScale;
      final r = await run(st, 'set_preferences', {'ui_scale': 5.0});
      expect(r.text, contains('ERROR'));
      expect(st.uiScale, before);
    });

    test('越界的 max_stations 被拒、合法值被接受', () async {
      final st = AppState();
      expect((await run(st, 'set_station_filters', {'max_stations': -1})).text,
          contains('ERROR'));
      final ok = await run(st, 'set_station_filters', {'max_stations': 1234});
      expect(ok.text, isNot(contains('ERROR')));
      expect(st.maxStations, 1234);
    });

    test('字符串数字被接受（模型常把数字当字符串传）', () async {
      final st = AppState();
      final r = await run(st, 'set_station_filters', {'max_stations': '4321'});
      expect(r.text, isNot(contains('ERROR')));
      expect(st.maxStations, 4321);
    });

    test('未知工具名被拒', () async {
      final r = await run(AppState(), 'do_something_wild', {});
      expect(r.text, contains('Unknown tool'));
    });
  });

  group('参数提取（_val 的 null 归一）', () {
    test('缺少 focus_call 时不会拿 "NULL" 去搜台站', () async {
      final st = AppState();
      // 没传 focus_call：若 _val 把 null 变成 "null"，这里会去搜 "NULL" 并
      // 报「Station NULL not found」，而不是正常切到 map 页。
      final r = await run(st, 'navigate', {'screen': 'map'});
      expect(r.text, isNot(contains('not found')));
      expect(r.text, isNot(contains('ERROR')));
    });

    test('search_stations 缺 query 时报错而不是搜 "null"', () async {
      final r = await run(AppState(), 'search_stations', {});
      expect(r.text, contains('ERROR'));
    });
  });

  group('身份信息', () {
    test('set_nickname 同时改呼号/SSID/备注并落盘', () async {
      final st = AppState();
      final r = await run(st, 'set_nickname', {
        'callsign': 'bd7abc',
        'ssid': 7,
        'comment': 'hello',
      });
      expect(r.text, isNot(contains('ERROR')));
      expect(st.myCall, 'BD7ABC');
      expect(st.mySsid, 7);
      expect(st.myComment, 'hello');
      expect(st.myFullCall, 'BD7ABC-7');
    });

    test('非法呼号（含空格）被拒、不改动现有值', () async {
      final st = AppState();
      final before = st.myCall;
      final r = await run(st, 'set_nickname', {'callsign': 'BAD CALL'});
      expect(r.text, contains('ERROR'));
      expect(st.myCall, before);
    });
  });

  group('只读工具', () {
    test('get_app_state 返回可解析的 JSON 且含允许值', () async {
      final st = AppState();
      final r = await run(st, 'get_app_state', {});
      expect(r.text, isNot(contains('ERROR')));
      final decoded = jsonDecodeSafe(r.text);
      expect(decoded, isA<Map>());
      expect((decoded as Map)['allowed_values'], isA<Map>());
    });

    test('list_groups 返回数组', () async {
      final r = await run(AppState(), 'list_groups', {});
      expect(jsonDecodeSafe(r.text), isA<List>());
    });

    test('search_stations 命中已存在的台站', () async {
      final st = AppState();
      st.stations.add(Station(
        call: 'BG7LZQ-9',
        symbol: '>',
        lat: 1,
        lng: 2,
        lastHeard: DateTime.now(),
      ));
      final r = await run(st, 'search_stations', {'query': 'bg7'});
      expect(r.text, contains('BG7LZQ-9'));
    });

    test('list_stations 按最近听到排序（最新在前）', () async {
      final st = AppState();
      final now = DateTime.now();
      st.stations.add(Station(
          call: 'OLD', symbol: '>', lat: 0, lng: 0,
          lastHeard: now.subtract(const Duration(hours: 2))));
      st.stations.add(Station(
          call: 'NEW', symbol: '>', lat: 0, lng: 0,
          lastHeard: now));
      final list = jsonDecodeSafe(
              (await run(st, 'list_stations', {'limit': 10})).text) as List;
      expect(list.first['call'], 'NEW');
    });

    test('station_detail 取到更全字段；未知呼号报错', () async {
      final st = AppState();
      st.stations.add(Station(
          call: 'BG7LZQ-9', symbol: '>', lat: 1, lng: 2,
          lastHeard: DateTime.now()));
      final ok = jsonDecodeSafe(
              (await run(st, 'station_detail', {'call': 'bg7lzq-9'})).text) as Map;
      expect(ok['call'], 'BG7LZQ-9');
      expect(ok.containsKey('track_points'), isTrue);
      final bad = await run(st, 'station_detail', {'call': 'NOPE'});
      expect(bad.text, contains('ERROR'));
    });

    test('read_messages 返回消息且不含 "null" 字面量', () async {
      final st = AppState();
      st.messages.insert(0,
          AprsMsg('BG7LZQ', st.myFullCall, 'hello there', DateTime.now()));
      final r = await run(st, 'read_messages', {'limit': 10});
      expect(r.text, isNot(contains('ERROR')));
      final list = jsonDecodeSafe(r.text) as List;
      expect(list, isNotEmpty);
      expect(list.first['text'], 'hello there');
    });
  });

  group('定时任务工具', () {
    test('未授权时 create_task / cancel_task 被拒（list_tasks 不受限）', () async {
      final st = AppState();
      final r = await run(st, 'create_task', {'prompt': 'ping'},
          allowTasks: false);
      expect(r.text, contains('Permission denied'));
      final l = await run(st, 'list_tasks', {}, allowTasks: false);
      expect(l.text, isNot(contains('Permission denied')));
    });

    test('授权后能建、列、取消；间隔过短被拒', () async {
      final st = AppState();
      final short = await run(
          st, 'create_task', {'prompt': 'x', 'interval_minutes': 1},
          allowTasks: true);
      expect(short.text, contains('ERROR'));

      final created = await run(
          st, 'create_task', {'prompt': 'summarize', 'interval_minutes': 30},
          allowTasks: true);
      expect(created.text, isNot(contains('ERROR')));
      expect(AgentService.instance.tasks.length, 1);

      final listed = jsonDecodeSafe(
          (await run(st, 'list_tasks', {}, allowTasks: true)).text) as List;
      expect(listed.single['prompt'], 'summarize');
      expect(listed.single['every_min'], 30);

      final id = listed.single['id'] as String;
      final canceled =
          await run(st, 'cancel_task', {'id': id}, allowTasks: true);
      expect(canceled.text, isNot(contains('ERROR')));
      expect(AgentService.instance.tasks, isEmpty);
    });
  });

  group('免确认判定（agentNeedsConfirm）', () {
    test('只读工具免确认，写工具要确认，navigate 豁免', () {
      for (final name in [
        'get_app_state',
        'list_groups',
        'list_stations',
        'search_stations',
        'station_detail',
        'read_messages',
        'list_tasks',
      ]) {
        expect(agentNeedsConfirm(name), isFalse, reason: name);
      }
      for (final name in [
        'send_message',
        'set_preferences',
        'create_task',
        'cancel_task',
      ]) {
        expect(agentNeedsConfirm(name), isTrue, reason: name);
      }
      expect(agentNeedsConfirm('navigate'), isFalse);
    });

    test('任务工具的 schema 仅在授权后出现', () {
      final off = agentToolSchemas(allowSend: false, allowTasks: false)
          .map((t) => t['function']['name'])
          .toSet();
      expect(off, isNot(contains('create_task')));
      expect(off, isNot(contains('list_tasks')));
      final on = agentToolSchemas(allowSend: false, allowTasks: true)
          .map((t) => t['function']['name'])
          .toSet();
      expect(on, contains('create_task'));
      expect(on, contains('list_tasks'));
    });
  });

  group('配置与任务持久化（round-trip）', () {
    test('AgentConfig 序列化含 alwaysAllow / 自动回复 / 任务权限', () {
      final c = AgentConfig()
        ..autoReply = true
        ..replyGroups = true
        ..autoReplyCooldownSec = 120
        ..quietHours = '23:00-07:00'
        ..allowTasks = true
        ..alwaysAllow.addAll({'navigate', 'set_preferences'});
      final back = AgentConfig.fromJson(jsonDecode(jsonEncode(c.toJson())));
      expect(back.autoReply, isTrue);
      expect(back.replyGroups, isTrue);
      expect(back.autoReplyCooldownSec, 120);
      expect(back.quietHours, '23:00-07:00');
      expect(back.allowTasks, isTrue);
      expect(back.alwaysAllow, containsAll(['navigate', 'set_preferences']));
    });

    test('AgentTask 序列化保留 id / 间隔 / 上次运行', () {
      final t = AgentTask(
        id: 't1',
        prompt: 'ping',
        intervalMinutes: 15,
        lastRun: DateTime.parse('2026-01-01T00:00:00Z'),
      );
      final back = AgentTask.fromJson(jsonDecode(jsonEncode(t.toJson())))!;
      expect(back.id, 't1');
      expect(back.prompt, 'ping');
      expect(back.intervalMinutes, 15);
      expect(back.lastRun, t.lastRun);
      // 空 prompt 的任务被丢弃（避免历史脏数据造出空转任务）。
      expect(AgentTask.fromJson({'id': 'x', 'prompt': '  '}), isNull);
    });

    test('quietHours 跨零点判断', () {
      final svc = AgentService.instance;
      svc.config.quietHours = '23:00-07:00';
      expect(svc.inQuietHours(DateTime(2026, 1, 1, 23, 30)), isTrue);
      expect(svc.inQuietHours(DateTime(2026, 1, 1, 3, 0)), isTrue);
      expect(svc.inQuietHours(DateTime(2026, 1, 1, 12, 0)), isFalse);
      svc.config.quietHours = '09:00-17:00';
      expect(svc.inQuietHours(DateTime(2026, 1, 1, 10, 0)), isTrue);
      expect(svc.inQuietHours(DateTime(2026, 1, 1, 18, 0)), isFalse);
      // 非法格式 → 不视为安静时段（宁可不拦，也不要误拦）。
      svc.config.quietHours = 'nonsense';
      expect(svc.inQuietHours(DateTime(2026, 1, 1, 10, 0)), isFalse);
      svc.config.quietHours = '';
    });

    test('循环任务的 nextRun 与 dueTasks', () {
      final t = AgentTask(
        id: 't1',
        prompt: 'ping',
        intervalMinutes: 10,
        createdAt: DateTime(2026, 1, 1, 0, 0),
      );
      expect(t.nextRun, DateTime(2026, 1, 1, 0, 10));
      expect(t.dueTasksProbe(DateTime(2026, 1, 1, 0, 5)), isFalse);
      expect(t.dueTasksProbe(DateTime(2026, 1, 1, 0, 11)), isTrue);
      // 只跑一次的任务：跑过 lastRun 后不再触发。
      final once = AgentTask(
        id: 't2',
        prompt: 'ping',
        createdAt: DateTime(2026, 1, 1, 0, 0),
      );
      expect(once.nextRun, DateTime(2026, 1, 1, 0, 0));
      once.lastRun = DateTime(2026, 1, 1, 0, 0);
      expect(once.nextRun, isNull);
    });
  });

  group('连接工具', () {
    test('set_connection_server 改地址与端口；端口越界被拒', () async {
      final st = AppState();
      final r = await run(st, 'set_connection_server',
          {'server': 'test.aprs.net', 'port': 14580});
      expect(r.text, contains('test.aprs.net'));
      expect(st.aprs.server, 'test.aprs.net');
      expect(st.aprs.port, 14580);

      final bad = await run(st, 'set_connection_server', {'port': 70000});
      expect(bad.text, contains('port'));
      expect(st.aprs.port, 14580); // 越界不写入
    });

    test('set_connection_source 启停来源；不允许关掉最后一个', () async {
      final st = AppState();
      await run(st, 'set_connection_source', {'source': 'tnc', 'enabled': true});
      expect(st.tncOn, isTrue);

      await run(st, 'set_connection_source',
          {'source': 'aprsis', 'enabled': false});
      expect(st.aprsIsOn, isFalse);

      // tnc 是仅剩的来源，不能再关
      final last = await run(st, 'set_connection_source',
          {'source': 'tnc', 'enabled': false});
      expect(last.text, contains('At least one'));
      expect(st.tncOn, isTrue);

      final bogus = await run(st, 'set_connection_source',
          {'source': 'bogus', 'enabled': true});
      expect(bogus.text, contains('source must be'));
    });

    test('未签署告知时 connect 被拒（不发起网络连接）', () async {
      final st = AppState();
      expect(st.dataNoticeAccepted, isFalse);
      final r = await run(st, 'connect', {});
      expect(r.text, contains('notice'));
    });

    test('disconnect 在未连接时返回已断开', () async {
      final st = AppState();
      final r = await run(st, 'disconnect', {});
      expect(r.text, contains('Already disconnected'));
    });

    test('get_app_state 暴露连接信息', () async {
      final st = AppState();
      st.aprs.server = 'x.example';
      final r = await run(st, 'get_app_state', {});
      final m = jsonDecodeSafe(r.text) as Map<String, dynamic>;
      final c = m['connections'] as Map<String, dynamic>;
      expect(c['server'], 'x.example');
      expect((c['sources'] as Map)['aprsis'], isTrue);
    });

    test('连接类工具受「修改设置」权限约束', () async {
      final st = AppState();
      final r = await run(st, 'set_connection_server', {'server': 'a.b'},
          allowSettings: false);
      expect(r.text, contains('Permission denied'));
      expect(st.aprs.server, isNot('a.b'));
    });
  });
}

/// 测试里不想引 dart:convert 只用一次，包一层返回 null 表示解析失败。
Object? jsonDecodeSafe(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}

extension on AgentTask {
  bool dueTasksProbe(DateTime now) =>
      nextRun != null && !nextRun!.isAfter(now);
}
