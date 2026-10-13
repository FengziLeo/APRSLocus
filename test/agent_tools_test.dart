import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aprslocus/agent.dart';
import 'package:aprslocus/agent_tools.dart';
import 'package:aprslocus/models.dart';
import 'package:aprslocus/state.dart';
import 'package:aprslocus/strategy_map.dart';

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
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentService.instance.tasks.clear();
    AgentService.instance.messages.clear();
    AgentService.instance.memories.clear();
  });

  Future<AgentToolOutcome> run(
    AppState st,
    String name,
    Map<String, dynamic> args, {
    bool allowSend = true,
    bool allowSettings = true,
    bool allowedNetwork = true,
  }) =>
      executeAgentTool(st, name, args,
          allowedSend: allowSend,
          allowedSettings: allowSettings,
          allowedNetwork: allowedNetwork);

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

    test('联网工具默认隐藏，开启后才出现且需权限', () async {
      Set<Object?> names({required bool net}) => agentToolSchemas(
              allowSend: true, allowNetwork: net)
          .map((t) => t['function']['name'])
          .toSet();
      expect(names(net: false), isNot(contains('http_request')));
      expect(names(net: true), contains('http_request'));
      // 即使 schema 被绕过，执行层闸门也要拒绝。
      final r = await run(
          AppState(), 'http_request', {'url': 'https://example.com'},
          allowedNetwork: false);
      expect(r.text, contains('Permission denied'));
      expect(agentNeedsConfirm('http_request'), isTrue);
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
      final obj = jsonDecodeSafe(r.text) as Map;
      final list = obj['messages'] as List;
      expect(list, isNotEmpty);
      expect(list.first['text'], 'hello there');
    });

    test('read_messages 支持关键字与时间过滤，并如实报告是否标记已读', () async {
      final st = AppState();
      final now = DateTime.now();
      st.messages.insert(
          0, AprsMsg('BG7LZQ', st.myFullCall, 'alpha one', now));
      st.messages.insert(
          0,
          AprsMsg('BG7LZQ', st.myFullCall, 'beta two',
              now.subtract(const Duration(hours: 2))));

      final kw = jsonDecodeSafe(
              (await run(st, 'read_messages', {'query': 'alpha'})).text)
          as Map;
      expect((kw['messages'] as List).length, 1);
      // 关键字过滤不代表「读完了」，不能顺手清未读。
      expect(kw['marked_read'], isFalse);

      final time = jsonDecodeSafe((await run(st, 'read_messages', {
        'since': now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
      })).text) as Map;
      expect((time['messages'] as List).length, 1);
    });
  });

  group('定时任务工具', () {
    test('无权限闸门：直接能建、列、取消', () async {
      final st = AppState();
      final created = await run(
          st, 'create_task', {'prompt': 'summarize', 'interval_minutes': 30});
      expect(created.text, isNot(contains('ERROR')));
      expect(AgentService.instance.tasks.length, 1);

      final listed = jsonDecodeSafe((await run(st, 'list_tasks', {})).text) as List;
      expect(listed.single['prompt'], 'summarize');
      expect(listed.single['every_min'], 30);

      final id = listed.single['id'] as String;
      final canceled = await run(st, 'cancel_task', {'id': id});
      expect(canceled.text, isNot(contains('ERROR')));
      expect(AgentService.instance.tasks, isEmpty);
    });

    test('create_task 支持消息触发（trigger=message）', () async {
      final st = AppState();
      final created = await run(st, 'create_task',
          {'prompt': 'note the location', 'trigger': 'message'});
      expect(created.text, isNot(contains('ERROR')));
      final t = AgentService.instance.tasks.single;
      expect(t.trigger, AgentTaskTrigger.message);
      // 消息触发型没有「下一次时刻」，也就不会被定时轮询当成到期任务。
      expect(t.nextRun, isNull);
      expect(AgentService.instance.dueTasks(DateTime(2030)), isEmpty);

      final listed =
          jsonDecodeSafe((await run(st, 'list_tasks', {})).text) as List;
      expect(listed.single['trigger'], 'message');
      expect(listed.single['every_min'], 0);
    });

    test('消息触发任务只由 messageTasks 选出，且与自动回复开关无关', () {
      final svc = AgentService.instance;
      svc.tasks
        ..clear()
        ..addAll([
          AgentTask(id: 'm1', prompt: 'a', trigger: AgentTaskTrigger.message),
          AgentTask(id: 'm2', prompt: 'b', trigger: AgentTaskTrigger.message),
          AgentTask(
              id: 't1',
              prompt: 'c',
              trigger: AgentTaskTrigger.timer,
              intervalMinutes: 5),
        ]);
      // 关掉自动回复：消息任务**仍**应被选出（BG7LZQ-2 报告的核心回归点 ——
      // 旧实现把它挂在 canAutoReply 上，默认关时静默永不触发）。
      svc.config.autoReply = false;
      expect(svc.canAutoReply(DateTime(2026, 1, 1, 12, 0)), isFalse);
      expect(
        svc.messageTasks().map((t) => t.id).toList(),
        ['m1', 'm2'],
      );
      // 禁用的消息任务不选。
      svc.tasks[1].enabled = false;
      expect(svc.messageTasks().map((t) => t.id).toList(), ['m1']);
      svc.tasks.clear();
    });

    test('touchTaskRun 记录 last_run 但不把消息任务停用', () async {
      final svc = AgentService.instance;
      svc.tasks
        ..clear()
        ..add(AgentTask(
            id: 'm9',
            prompt: 'x',
            trigger: AgentTaskTrigger.message,
            enabled: true));
      expect(svc.tasks.single.lastRun, isNull);
      await svc.touchTaskRun('m9');
      // 关键：last_run 有值（用户据此判定「跑过了」），且任务仍启用
      // —— markTaskRun 会因 recurring==false 把它永久关掉，故不能复用。
      expect(svc.tasks.single.lastRun, isNotNull);
      expect(svc.tasks.single.enabled, isTrue);
      svc.tasks.clear();
    });

    test('并发 load() 共享同一份 Future，读完才置 loaded', () async {
      final svc = AgentService.instance;
      final a = svc.load();
      final b = svc.load();
      // 幂等：并发的两个调用拿到同一个 Future，不会各自读一遍盘、
      // 也不会第二个调用提前返回去跑空数据（冷启动丢消息任务的根因）。
      expect(identical(a, b), isTrue);
      await a;
      expect(svc.loaded, isTrue);
      expect(identical(svc.load(), a), isTrue); // 之后再调用仍是同一份
    });

    test('create_task 未给 trigger 仍按定时处理（兼容旧行为）', () async {
      final st = AppState();
      await run(st, 'create_task', {'prompt': 'ping', 'interval_minutes': 5});
      final t = AgentService.instance.tasks.single;
      expect(t.trigger, AgentTaskTrigger.timer);
      expect(t.nextRun, isNotNull);
    });

    test('间隔不受限（1 分钟也可）', () async {
      final st = AppState();
      final r = await run(
          st, 'create_task', {'prompt': 'x', 'interval_minutes': 1});
      expect(r.text, isNot(contains('ERROR')));
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
        'nearby_stations',
      ]) {
        expect(agentNeedsConfirm(name), isFalse, reason: name);
      }
      for (final name in [
        'send_message',
        'reply_message',
        'send_group_message',
        'create_group',
        'set_preferences',
        'create_task',
        'cancel_task',
        'set_task_enabled',
      ]) {
        expect(agentNeedsConfirm(name), isTrue, reason: name);
      }
      expect(agentNeedsConfirm('navigate'), isFalse);
    });

    test('任务工具的 schema 始终可用（不再有权限开关）', () {
      final names = agentToolSchemas(allowSend: false)
          .map((t) => t['function']['name'])
          .toSet();
      expect(names, contains('create_task'));
      expect(names, contains('list_tasks'));
      expect(names, contains('set_task_enabled'));
    });

    test('未授权发送时 reply_message 也不出现（它同样是发送）', () {
      final off = agentToolSchemas(allowSend: false)
          .map((t) => t['function']['name'])
          .toSet();
      expect(off, isNot(contains('reply_message')));
      final on = agentToolSchemas(allowSend: true)
          .map((t) => t['function']['name'])
          .toSet();
      expect(on, contains('reply_message'));
    });
  });

  group('新增工具', () {
    test('create_group 建群并加入成员', () async {
      final st = AppState();
      final r = await run(st, 'create_group', {
        'name': '测试群',
        'members': ['BG1AAA', 'bg2bbb'],
      });
      expect(r.text, isNot(contains('ERROR')));
      expect(st.chatGroups.length, 1);
      final g = st.chatGroups.single;
      expect(g.name, '测试群');
      // 成员统一大写，群主自动 joined
      expect(g.memberStatus.containsKey('BG1AAA'), isTrue);
      expect(g.memberStatus.containsKey('BG2BBB'), isTrue);
      expect(g.owner, g.owner.toUpperCase());
    });

    test('create_group 缺 name 被拒', () async {
      final st = AppState();
      final r = await run(st, 'create_group', {'name': '  '});
      expect(r.text, contains('ERROR'));
      expect(st.chatGroups, isEmpty);
    });

    test('nearby_stations 无定位时给出明确错误', () async {
      final st = AppState();
      final r = await run(st, 'nearby_stations', {});
      expect(r.text, contains('ERROR'));
    });

    test('send_group_message 找不到群时给出错误', () async {
      final st = AppState();
      final r = await run(st, 'send_group_message', {'group': 'nope', 'text': 'hi'});
      expect(r.text, contains('ERROR'));
    });

    test('set_task_enabled 可暂停 / 恢复', () async {
      final st = AppState();
      final t = await AgentService.instance.addTask('ping', intervalMinutes: 10);
      final off = await run(st, 'set_task_enabled', {'id': t.id, 'enabled': false});
      expect(off.text, isNot(contains('ERROR')));
      expect(AgentService.instance.tasks.single.enabled, isFalse);
      final on = await run(st, 'set_task_enabled', {'id': t.id, 'enabled': true});
      expect(on.text, isNot(contains('ERROR')));
      expect(AgentService.instance.tasks.single.enabled, isTrue);
    });
  });

  group('配置与任务持久化（round-trip）', () {
    test('AgentConfig 序列化含 alwaysAllow / 自动回复', () {
      final c = AgentConfig()
        ..autoReply = true
        ..replyGroups = true
        ..autoReplyCooldownSec = 120
        ..quietHours = '23:00-07:00'
        ..alwaysAllow.addAll({'navigate', 'set_preferences'});
      final back = AgentConfig.fromJson(jsonDecode(jsonEncode(c.toJson())));
      expect(back.autoReply, isTrue);
      expect(back.replyGroups, isTrue);
      expect(back.autoReplyCooldownSec, 120);
      expect(back.quietHours, '23:00-07:00');
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
      expect(back.trigger, AgentTaskTrigger.timer);
      expect(back.intervalMinutes, 15);
      expect(back.lastRun, t.lastRun);
      // 空 prompt 的任务被丢弃（避免历史脏数据造出空转任务）。
      expect(AgentTask.fromJson({'id': 'x', 'prompt': '  '}), isNull);
    });

    test('AgentTask 序列化保留消息触发类型；旧数据默认定时', () {
      final t = AgentTask(
        id: 't2',
        prompt: 'on msg',
        trigger: AgentTaskTrigger.message,
      );
      final back = AgentTask.fromJson(jsonDecode(jsonEncode(t.toJson())))!;
      expect(back.trigger, AgentTaskTrigger.message);
      // 老数据没有 trigger 字段 → 回退为定时，行为不变。
      final legacy = AgentTask.fromJson({'id': 't3', 'prompt': 'old'})!;
      expect(legacy.trigger, AgentTaskTrigger.timer);
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

  group('任务编辑与执行记录', () {
    test('update_task 就地改提示词与间隔', () async {
      final st = AppState();
      await run(st, 'create_task', {'prompt': 'old', 'interval_minutes': 30});
      final id = AgentService.instance.tasks.single.id;
      final r = await run(st, 'update_task',
          {'id': id, 'prompt': 'new', 'interval_minutes': 5});
      expect(r.text, isNot(contains('ERROR')));
      final t = AgentService.instance.tasks.single;
      expect(t.prompt, 'new');
      expect(t.intervalMinutes, 5);
    });

    test('update_task 支持绝对时刻 run_at（只跑一次）', () async {
      final st = AppState();
      await run(st, 'create_task', {'prompt': 'x', 'interval_minutes': 30});
      final id = AgentService.instance.tasks.single.id;
      final when = DateTime(2030, 1, 2, 3, 4);
      final r = await run(st, 'update_task', {'id': id, 'run_at': when.toIso8601String()});
      expect(r.text, isNot(contains('ERROR')));
      final t = AgentService.instance.tasks.single;
      expect(t.runAt, when);
      expect(t.recurring, isFalse);
      // 还没到点，不应被当作到期任务。
      expect(AgentService.instance.dueTasks(DateTime(2029)), isEmpty);
    });

    test('update_task 未知 id 报错', () async {
      final st = AppState();
      final r = await run(st, 'update_task', {'id': 'nope', 'prompt': 'x'});
      expect(r.text, contains('ERROR'));
    });

    test('recordTaskRun / list_task_runs 记录并可清空', () async {
      final st = AppState();
      await AgentService.instance.recordTaskRun('t1', 'p', true, 'done');
      final listed = jsonDecodeSafe((await run(st, 'list_task_runs', {})).text) as List;
      expect(listed.single['task_id'], 't1');
      expect(listed.single['ok'], isTrue);
      await run(st, 'clear_task_runs', {});
      final after = jsonDecodeSafe((await run(st, 'list_task_runs', {})).text) as List;
      expect(after, isEmpty);
    });

    test('AgentTaskRun 序列化保留字段', () {
      final r = AgentTaskRun(
          taskId: 't9', prompt: 'p', at: DateTime(2026), ok: false, summary: 's');
      final back = AgentTaskRun.fromJson(r.toJson())!;
      expect(back.taskId, 't9');
      expect(back.ok, isFalse);
      expect(back.summary, 's');
    });
  });

  group('群管理工具', () {
    test('list_groups 现在带成员', () async {
      final st = AppState();
      st.createGroup('Team', {'BG1AAA', 'BG2BBB'});
      final list = jsonDecodeSafe((await run(st, 'list_groups', {})).text) as List;
      final g = list.single as Map;
      expect(g['owner'], st.myCall);
      expect(g['is_owner'], isTrue);
      final members = g['members'] as List;
      expect(members.length, 3); // 群主 + 两位成员
    });

    test('update_group 改名并加/删成员', () async {
      final st = AppState();
      final g = st.createGroup('Team', {'BG1AAA'});
      final r = await run(st, 'update_group', {
        'group': 'Team',
        'name': 'Renamed',
        'add': ['BG2BBB'],
        'remove': ['BG1AAA'],
      });
      expect(r.text, isNot(contains('ERROR')));
      final grp = st.chatGroups.single;
      expect(grp.name, 'Renamed');
      expect(grp.allMemberCalls, contains('BG2BBB'));
      expect(grp.allMemberCalls, isNot(contains('BG1AAA')));
      // 自己不应被移除
      expect(grp.recipients, contains(st.myCall.toUpperCase()));
      expect(g.id, grp.id);
    });

    test('leave_group / join_group 改变自身成员状态', () async {
      final st = AppState();
      st.createGroup('Team', {'BG1AAA'});
      final left = await run(st, 'leave_group', {'group': 'Team'});
      expect(left.text, isNot(contains('ERROR')));
      expect(st.chatGroups.single.recipients, isNot(contains(st.myCall.toUpperCase())));
      final joined = await run(st, 'join_group', {'group': 'Team'});
      expect(joined.text, isNot(contains('ERROR')));
      expect(st.chatGroups.single.recipients, contains(st.myCall.toUpperCase()));
    });

    test('dismiss_group 删除群', () async {
      final st = AppState();
      st.createGroup('Team', {'BG1AAA'});
      final r = await run(st, 'dismiss_group', {'group': 'Team'});
      expect(r.text, isNot(contains('ERROR')));
      expect(st.chatGroups, isEmpty);
    });
  });

  group('台站：收藏 / 屏蔽 / 数据', () {
    test('set_favorite 关注不存在的呼号会补一条手动台站', () async {
      final st = AppState();
      final r = await run(st, 'set_favorite', {'call': 'bg9zzz', 'favorite': true});
      expect(r.text, isNot(contains('ERROR')));
      expect(st.stations.where((s) => s.call == 'BG9ZZZ').single.favorite, isTrue);
      final contacts = jsonDecodeSafe((await run(st, 'list_contacts', {})).text) as List;
      expect(contacts.single['call'], 'BG9ZZZ');
    });

    test('set_station_ignored 隐藏台站（upsert 被跳过）', () async {
      final st = AppState();
      st.setStationIgnored('BAD', true);
      expect(st.isStationIgnored('bad'), isTrue);
      final r = await run(st, 'set_station_ignored', {'call': 'BAD', 'ignored': false});
      expect(r.text, isNot(contains('ERROR')));
      expect(st.isStationIgnored('BAD'), isFalse);
    });

    test('get_station_packets 返回原始帧', () async {
      final st = AppState();
      st.packets.insert(0,
          Packet('BG1>APRS:x', 'BG1', 'APRS', 'message', DateTime.now()));
      final list = jsonDecodeSafe(
              (await run(st, 'get_station_packets', {'call': 'BG1'})).text) as List;
      expect(list.single['raw'], 'BG1>APRS:x');
    });

    test('get_track / export_track_gpx 走自身轨迹', () async {
      final st = AppState();
      st.myTrack.add(TrackPt(1, 2, DateTime(2026)));
      final js = jsonDecodeSafe((await run(st, 'get_track', {'call': 'me'})).text) as List;
      expect(js.single['lat'], 1);
      final gpx = await run(st, 'export_track_gpx', {'call': 'me'});
      expect(gpx.text, contains('<gpx'));
      expect(gpx.text, contains('lat="1.0"'));
    });

    test('distance_between 计算距离与方位', () async {
      final st = AppState();
      st.setMyPosition(0, 0);
      st.stations.add(Station(
          call: 'FAR', symbol: '>', lat: 0, lng: 1, lastHeard: DateTime.now()));
      final m = jsonDecodeSafe(
              (await run(st, 'distance_between', {'from': 'me', 'to': 'FAR'})).text)
          as Map;
      expect(m['distance_m'], greaterThan(110000));
      expect(m['distance_m'], lessThan(112000));
      expect(m['initial_bearing_deg'], 90); // 正东
    });
  });

  group('传感器 / 位置 / 状态 / 群发', () {
    test('get_sensors 无数据时字段为 null 而非 "null"', () async {
      final st = AppState();
      final r = await run(st, 'get_sensors', {});
      expect(r.text, isNot(contains('ERROR')));
      final m = jsonDecodeSafe(r.text) as Map;
      expect(m.containsKey('heart_rate_bpm'), isTrue);
      expect(m['heart_rate_bpm'], isNull);
      expect(m['steps_today'], 0);
    });

    test('set_status_text 写入状态文本', () async {
      final st = AppState();
      final r = await run(st, 'set_status_text', {'text': 'On the air'});
      expect(r.text, isNot(contains('ERROR')));
      expect(st.aprsStatusText, 'On the air');
    });

    test('broadcast_message 逐个收件人入队，受发送权限约束', () async {
      final st = AppState();
      final ok = await run(st, 'broadcast_message', {
        'to': ['BG1', 'BG2'],
        'text': 'hi all',
      });
      expect(ok.text, isNot(contains('ERROR')));
      expect(st.messages.where((m) => m.sent).length, 2);

      final denied = await run(st, 'broadcast_message', {
        'to': ['BG3'],
        'text': 'x',
      }, allowSend: false);
      expect(denied.text, contains('Permission denied'));
    });

    test('set_my_position 需要已签数据告知；clear 复位', () async {
      final st = AppState();
      final denied = await run(st, 'set_my_position', {'lat': 1, 'lng': 2});
      expect(denied.text, contains('ERROR'));
      st.dataNoticeAccepted = true;
      final ok = await run(st, 'set_my_position', {'lat': 1, 'lng': 2});
      expect(ok.text, isNot(contains('ERROR')));
      expect(st.myLat, 1);
      expect(st.useSimLocation, isTrue);
      final cleared = await run(st, 'clear_my_position', {});
      expect(cleared.text, isNot(contains('ERROR')));
      expect(st.useSimLocation, isFalse);
    });

    test('越界坐标被拒', () async {
      final st = AppState();
      st.dataNoticeAccepted = true;
      final r = await run(st, 'set_my_position', {'lat': 200, 'lng': 0});
      expect(r.text, contains('ERROR'));
    });
  });

  group('权限可见性', () {
    test('get_app_state 暴露 permissions 与自身位置时间', () async {
      final st = AppState();
      final m = jsonDecodeSafe((await run(st, 'get_app_state', {})).text)
          as Map<String, dynamic>;
      final p = m['permissions'] as Map;
      expect(p.containsKey('allow_send'), isTrue);
      expect(p.containsKey('allow_settings'), isTrue);
      expect(m.containsKey('my_fix_min_ago'), isTrue);
    });
  });

  group('长期记忆', () {
    test('save_memory 去重 / 截断 / list / forget 全链路', () async {
      final svc = AgentService.instance;
      final st = AppState();
      // 未授权改设置时不该写入。
      final denied = await run(st, 'save_memory', {'text': 'x'},
          allowSettings: false);
      expect(denied.text, contains('Permission denied'));
      expect(svc.memories, isEmpty);

      expect((await run(st, 'save_memory', {'text': '呼号 BG2HCB'})).text,
          contains('saved'));
      // 相同文本二次写入 = 刷新而非新增。
      expect((await run(st, 'save_memory', {'text': '呼号 BG2HCB'})).text,
          contains('Already'));
      expect(svc.memories.length, 1);
      // 超长文本被截断，不会无限增长。
      await run(st, 'save_memory', {'text': 'z' * 900});
      expect(svc.memories.last.text.length, 500);

      final listed = jsonDecodeSafe((await run(st, 'list_memories', {})).text)
          as List;
      expect(listed.length, 2);
      // 按文本子串遗忘。
      expect((await run(st, 'forget_memory', {'key': 'BG2HCB'})).text,
          contains('1'));
      expect(svc.memories.length, 1);
      expect((await run(st, 'forget_memory', {'key': 'nope'})).text,
          contains('No matching'));
    });

    test('记忆随配置序列化保留，并在开关关闭时不注入提示', () {
      final c = AgentConfig();
      expect(c.memoryEnabled, isTrue); // 默认开启
      final j = c.toJson();
      expect(j.containsKey('memoryEnabled'), isTrue);
      final back = AgentConfig.fromJson(j);
      expect(back.memoryEnabled, isTrue);
      back.memoryEnabled = false;
      expect(AgentConfig.fromJson(back.toJson()).memoryEnabled, isFalse);
    });

    test('对话压缩：条数不足时不做，且保留最近若干条', () async {
      final svc = AgentService.instance;
      svc.messages.clear();
      for (var i = 0; i < 5; i++) {
        svc.messages.add(AgentMessage(role: 'user', content: 'm$i'));
      }
      // 少于保留阈值（16）→ 直接返回 false，不动历史。
      expect(await svc.compressNow(), isFalse);
      expect(svc.messages.length, 5);
    });
  });

  group('消息到达事件（多监听者）', () {
    test('外壳的顶部气泡监听器不会顶掉智能体的消息任务回调', () {
      final st = AppState();
      final got = <String>[];
      void agentCb(String s, String t, String? g) => got.add('agent:$s/$t');
      void shellCb(String s, String t, String? g) => got.add('shell:$s/$t');
      // 智能体先注册（AgentOverlay.initState），外壳后注册（HomePage.initState）
      // —— 旧实现是单槽 `onNewMessage = f`，外壳这一句会把 agentCb 覆盖掉，
      // 于是「新消息来了但消息任务不触发」静默发生。
      st.addNewMessageListener(agentCb);
      st.addNewMessageListener(shellCb);
      st.emitNewMessageForTest('BG2HCB', 'hi', null);
      expect(got, containsAll(['agent:BG2HCB/hi', 'shell:BG2HCB/hi']));

      // 外壳重建（切布局/主题）只注销自己，智能体回调仍在。
      st.removeNewMessageListener(shellCb);
      got.clear();
      st.emitNewMessageForTest('BG2HCB', 'yo', null);
      expect(got, ['agent:BG2HCB/yo']);

      // 重复注册不产生重复投递。
      st.addNewMessageListener(agentCb);
      got.clear();
      st.emitNewMessageForTest('BG2HCB', 'dup', null);
      expect(got, ['agent:BG2HCB/dup']);
    });
  });

  group('策略地图工具', () {
    test('list_strategy 空群返回空数组', () async {
      final st = AppState();
      st.createGroup('Team', {'BG1AAA'});
      final r = await run(st, 'list_strategy', {'group': 'Team'});
      expect(r.text, isNot(contains('ERROR')));
      expect(jsonDecodeSafe(r.text), isEmpty);
    });

    test('strategy_add_point 落图，能自己列出来（mine=true）', () async {
      final st = AppState();
      final g = st.createGroup('Team', {'BG1AAA'});
      final add = await run(st, 'strategy_add_point',
          {'group': 'Team', 'lat': 39.9, 'lng': 116.4, 'label': '集合'});
      expect(add.text, isNot(contains('ERROR')));
      final items = st.strategyOf(g.groupCall);
      expect(items.length, 1);
      expect(items.single.kind, StrategyKind.point);
      expect(items.single.label, '集合');

      final list =
          jsonDecodeSafe((await run(st, 'list_strategy', {'group': 'Team'})).text)
              as List;
      expect(list.single['kind'], 'point');
      expect(list.single['mine'], isTrue);
      expect(list.single['lat'], 39.9);
    });

    test('strategy_add_line 解析 "lat,lng;lat,lng" 字符串', () async {
      final st = AppState();
      final g = st.createGroup('Team', {'BG1AAA'});
      final r = await run(st, 'strategy_add_line', {
        'group': 'Team',
        'points': '39.90,116.40;39.91,116.41;39.92,116.42',
      });
      expect(r.text, isNot(contains('ERROR')));
      final it = st.strategyOf(g.groupCall).single;
      expect(it.kind, StrategyKind.line);
      expect(it.path.length, 3);
      // 越界/畸形点一律拒绝，不静默落一半。
      final bad = await run(st, 'strategy_add_line',
          {'group': 'Team', 'points': '39.9,116.4;999,116.41'});
      expect(bad.text, contains('ERROR'));
    });

    test('strategy_add_circle 半径越界被拒', () async {
      final st = AppState();
      st.createGroup('Team', {'BG1AAA'});
      final r = await run(st, 'strategy_add_circle',
          {'group': 'Team', 'lat': 39.9, 'lng': 116.4, 'radius_m': 999999999});
      expect(r.text, contains('ERROR'));
    });

    test('strategy_update / delete 按 id 操作', () async {
      final st = AppState();
      final g = st.createGroup('Team', {'BG1AAA'});
      await run(st, 'strategy_add_point',
          {'group': 'Team', 'lat': 39.9, 'lng': 116.4});
      final id = st.strategyOf(g.groupCall).single.id;

      final upd = await run(st, 'strategy_update',
          {'group': 'Team', 'id': id, 'lat': 30.0, 'lng': 120.0, 'label': 'X'});
      expect(upd.text, isNot(contains('ERROR')));
      final it = st.strategyOf(g.groupCall).single;
      expect(it.id, id);
      expect(it.lat, 30.0);
      expect(it.label, 'X');

      final del = await run(st, 'strategy_delete', {'group': 'Team', 'id': id});
      expect(del.text, isNot(contains('ERROR')));
      expect(st.strategyOf(g.groupCall), isEmpty);
      // 删不存在的 id 要报错，而不是静默成功。
      final again = await run(st, 'strategy_delete', {'group': 'Team', 'id': id});
      expect(again.text, contains('ERROR'));
    });

    test('strategy_clear 清空整群', () async {
      final st = AppState();
      final g = st.createGroup('Team', {'BG1AAA'});
      await run(st, 'strategy_add_point', {'group': 'Team', 'lat': 1.0, 'lng': 2.0});
      await run(st, 'strategy_add_rally', {'group': 'Team', 'lat': 3.0, 'lng': 4.0});
      final r = await run(st, 'strategy_clear', {'group': 'Team'});
      expect(r.text, isNot(contains('ERROR')));
      expect(st.strategyOf(g.groupCall), isEmpty);
    });

    test('写工具需发送权限，list_strategy 免确认', () async {
      final st = AppState();
      st.createGroup('Team', {'BG1AAA'});
      final denied = await run(st, 'strategy_add_point',
          {'group': 'Team', 'lat': 1.0, 'lng': 2.0},
          allowSend: false);
      expect(denied.text, contains('Permission denied'));
      expect(st.strategyOf(st.chatGroups.single.groupCall), isEmpty);

      expect(agentNeedsConfirm('list_strategy'), isFalse);
      expect(agentNeedsConfirm('strategy_add_point'), isTrue);
    });

    test('找不到群时报错，不落任何元素', () async {
      final st = AppState();
      final r = await run(st, 'strategy_add_point',
          {'group': 'nope', 'lat': 1.0, 'lng': 2.0});
      expect(r.text, contains('ERROR'));
      expect(st.strategyItems, isEmpty);
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
