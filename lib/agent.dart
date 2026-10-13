/// ─── 智能体模式（AI Agent）───
///
/// 实验功能：用户自行配置一个 **OpenAI 兼容** 的接口（Base URL + Key + 模型），
/// 打开后屏幕上出现一个 AI 聊天框；智能体可以**调用工具**帮用户改设置、发消息、
/// 查台站。
///
/// ## 分层（为什么这样切）
///
/// * 本文件（`agent.dart`）：配置、对话历史、LLM 调用与**工具调用循环**。
///   它**不 import `state.dart`** —— 否则 `state.dart` 要引用本文件的配置时就会
///   循环导入。工具由上层通过回调注入：`send()` 只认「工具表 + 执行器 + 确认器」
///   三个回调，不知道 AppState 的存在。
/// * [agent_tools.dart]：把 AppState 包装成上面那三个回调（真正的工具实现）。
/// * [agent_ui.dart]：浮动聊天框 + 设置页。
///
/// ## 安全
///
/// Key 只存在本机 `SharedPreferences`，**不写日志、不进任何网络请求之外的用途**。
/// 改动设置 / 发送消息这类有副作用且不可撤销的操作，走 [AgentService.send] 的
/// `confirm` 回调 → 由界面弹确认框，用户点了「允许」才真正执行。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/http_send.dart';
import 'agent_stream.dart' show AgentStreamAssembler;

/// 一条工具调用（来自模型的 tool_calls）
class AgentToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  const AgentToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  static AgentToolCall fromJson(Map j) {
    final fn = (j['function'] as Map?) ?? const {};
    Map<String, dynamic> args = const {};
    final raw = fn['arguments'];
    if (raw is Map) {
      args = raw.map((k, v) => MapEntry('$k', v));
    } else if (raw is String && raw.trim().isNotEmpty) {
      // 不少兼容接口把 arguments 作为 JSON 字符串返回
      try {
        final d = jsonDecode(raw);
        if (d is Map) args = d.map((k, v) => MapEntry('$k', v));
      } catch (_) {}
    }
    return AgentToolCall(
      id: '${j['id'] ?? ''}',
      name: '${fn['name'] ?? ''}',
      arguments: args,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'function',
        'function': {
          'name': name,
          'arguments': jsonEncode(arguments),
        },
      };
}

/// 聊天消息（role 直接用 OpenAI 的写法，便于序列化）
class AgentMessage {
  final String role; // system / user / assistant / tool
  String content;
  List<AgentToolCall> toolCalls;
  String? toolCallId; // role=tool 时对应哪次调用
  String? name; // role=tool 时的工具名

  AgentMessage({
    required this.role,
    this.content = '',
    this.toolCalls = const [],
    this.toolCallId,
    this.name,
  });

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
  bool get isTool => role == 'tool';

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (toolCalls.isNotEmpty)
          'tool_calls': toolCalls.map((c) => c.toJson()).toList(),
        if (toolCallId != null) 'tool_call_id': toolCallId,
        if (name != null) 'name': name,
      };

  static AgentMessage fromJson(Map j) => AgentMessage(
        role: '${j['role'] ?? 'assistant'}',
        content: '${j['content'] ?? ''}',
        toolCalls: [
          for (final c in (j['tool_calls'] as List? ?? const []))
            if (c is Map) AgentToolCall.fromJson(c),
        ],
        toolCallId: j['tool_call_id']?.toString(),
        name: j['name']?.toString(),
      );
}

/// 一条长期记忆：跨对话保留的事实（偏好、称呼、常用地点……）。
///
/// 与 [AgentService.historySummary]（对话压缩出的摘要）分开存：记忆是**用户/
/// 模型主动要求记住**的稳定事实，摘要是系统自动折叠旧对话得到的过程性要点。
class AgentMemory {
  final String id;
  String text;
  final DateTime at;
  AgentMemory({required this.id, required this.text, required this.at});

  Map<String, dynamic> toJson() =>
      {'id': id, 'text': text, 'at': at.toIso8601String()};

  static AgentMemory? fromJson(Object? j) {
    if (j is! Map) return null;
    final t = '${j['text'] ?? ''}'.trim();
    if (t.isEmpty) return null;
    return AgentMemory(
      id: '${j['id'] ?? ''}'.isEmpty
          ? DateTime.now().microsecondsSinceEpoch.toRadixString(36)
          : '${j['id']}',
      text: t,
      at: DateTime.tryParse('${j['at']}') ?? DateTime.now(),
    );
  }
}

/// 智能体配置（全部由用户填写）
class AgentConfig {
  bool enabled;
  String baseUrl;
  String apiKey;
  String model;
  String systemPrompt;

  /// 允许智能体发送消息（私信 / 群消息 / 信标）
  bool allowSend;

  /// 允许智能体修改设置（关闭后只能查看）
  bool allowSettings;

  /// 免确认白名单：这些工具被执行时不再逐次弹确认（用户点过「始终允许」）。
  ///
  /// 与 [allowSettings] 的分工：后者是「能不能做」，这里只是「要不要每次问」。
  /// 敏感工具（发消息）默认不进这个名单，需要用户显式点「始终允许」才会加。
  Set<String> alwaysAllow;

  /// 收到别人发来的消息时，自动让智能体代拟一条回复（默认关，属实验能力）。
  ///
  /// 安全阀：只回复**私聊**（[replyGroups] 打开才含群聊）、受安静时段与冷却限制、
  /// 且仅当用户在最近一段时间内活跃过（避免后台无人值守时乱回复）。
  bool autoReply;

  /// 自动回复是否也覆盖群聊（默认关：群里自动说话风险更大）。
  bool replyGroups;

  /// 自动回复冷却：同一会话在这么多秒内不重复自动回复（防止双方机器人互刷）。
  int autoReplyCooldownSec;

  /// 安静时段，格式 `HH:MM-HH:MM`（可为空 = 不限）。跨零点（如 23:00-07:00）也支持。
  String quietHours;

  /// 联网权限：允许智能体主动发起 HTTP 请求（GET / POST / PUT / DELETE…）
  /// 访问用户指定的地址。默认关闭 —— 与 APRS 收发、改设置同级的显式权限。
  bool allowNetwork;

  /// 长期记忆：把 [AgentMemory] 注入系统提示，让智能体跨对话记住用户偏好。
  bool memoryEnabled;

  /// 对话压缩：历史变长时自动把旧对话折叠成一段摘要。
  bool compressEnabled;

  /// 逐字回复：走流式（SSE）接口，模型边生成边显示（见 [AgentService.streamText]）。
  ///
  /// 默认开。后端不认 `stream:true`（回一整段普通 JSON）或平台不支持时
  /// **自动退回**整段式，不会因此少一句回复 —— 只是不再逐字出现。
  bool streamReply;

  AgentConfig({
    this.enabled = false,
    this.baseUrl = 'https://api.openai.com/v1',
    this.apiKey = '',
    this.model = 'gpt-4o-mini',
    this.systemPrompt = '',
    this.allowSend = false,
    this.allowSettings = false,
    Set<String>? alwaysAllow,
    this.autoReply = false,
    this.replyGroups = false,
    this.autoReplyCooldownSec = 60,
    this.quietHours = '',
    this.allowNetwork = false,
    this.memoryEnabled = true,
    this.compressEnabled = true,
    this.streamReply = true,
  }) : alwaysAllow = alwaysAllow ?? <String>{};

  /// 配置是否已填写到「可发起请求」的程度
  bool get ready =>
      baseUrl.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty &&
      model.trim().isNotEmpty;

  /// 实际的 chat/completions 地址：用户既可填到 `/v1`，也可直接填带
  /// `/chat/completions` 的完整地址。
  String get endpoint {
    var u = baseUrl.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    if (u.endsWith('/chat/completions')) return u;
    return '$u/chat/completions';
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'systemPrompt': systemPrompt,
        'allowSend': allowSend,
        'allowSettings': allowSettings,
        'alwaysAllow': alwaysAllow.toList(),
        'autoReply': autoReply,
        'replyGroups': replyGroups,
        'autoReplyCooldownSec': autoReplyCooldownSec,
        'quietHours': quietHours,
        'allowNetwork': allowNetwork,
        'memoryEnabled': memoryEnabled,
        'compressEnabled': compressEnabled,
        'streamReply': streamReply,
      };

  static AgentConfig fromJson(Object? j) {
    final c = AgentConfig();
    if (j is! Map) return c;
    String s(String k, String fb) => j[k]?.toString() ?? fb;
    return AgentConfig(
      enabled: j['enabled'] == true,
      baseUrl: s('baseUrl', c.baseUrl),
      apiKey: s('apiKey', c.apiKey),
      model: s('model', c.model),
      systemPrompt: s('systemPrompt', c.systemPrompt),
      allowSend: j['allowSend'] == true,
      allowSettings: j['allowSettings'] == true,
      alwaysAllow: {
        for (final v in (j['alwaysAllow'] as List? ?? const [])) '$v',
      },
      autoReply: j['autoReply'] == true,
      replyGroups: j['replyGroups'] == true,
      autoReplyCooldownSec:
          int.tryParse('${j['autoReplyCooldownSec']}') ?? c.autoReplyCooldownSec,
      quietHours: s('quietHours', c.quietHours),
      allowNetwork: j['allowNetwork'] == true,
      // 新旧兼容：老配置里没有这两个键 → 默认开启（见构造函数默认值）。
      memoryEnabled: j.containsKey('memoryEnabled')
          ? j['memoryEnabled'] != false
          : c.memoryEnabled,
      compressEnabled: j.containsKey('compressEnabled')
          ? j['compressEnabled'] != false
          : c.compressEnabled,
      // 同上：老配置没有这个键 → 默认开启逐字回复。
      streamReply:
          j.containsKey('streamReply') ? j['streamReply'] != false : c.streamReply,
    );
  }
}

/// 一个由智能体「到点」或「收到消息」触发的任务，触发后以 [prompt] 作为用户
/// 指令跑一轮智能体。
///
/// 设计上**只存「做什么」不存「怎么发」**：真正执行走的是和手动聊天完全相同的
/// [AgentService.send] 路径（因此权限闸门、确认、工具链全部一致），定时器 / 消息
/// 回调只负责触发。这样「改了一处」不会出现「手动能用、触发不能用」的分叉。
///
/// [trigger] 区分两种触发源：定时（[AgentTaskTrigger.timer]）与收到消息
/// （[AgentTaskTrigger.message]）。二者的「做什么」是同一套，只是被谁唤醒不同。
enum AgentTaskTrigger { timer, message }

class AgentTask {
  final String id;
  String prompt;
  final DateTime createdAt;
  DateTime? lastRun;

  /// 触发源。默认定时（兼容旧数据）。
  AgentTaskTrigger trigger;

  /// 循环间隔（分钟）。0 = 只跑一次。[trigger] 为 message 或设置了 [runAt] 时不使用。
  int intervalMinutes;

  /// 绝对时刻（只跑一次）。设置了它就以它为准（「今晚 8 点」不必再自己算分钟）。
  /// 跑过之后 [nextRun] 返回 null，不再触发。
  DateTime? runAt;

  bool enabled;

  AgentTask({
    required this.id,
    required this.prompt,
    DateTime? createdAt,
    this.lastRun,
    this.trigger = AgentTaskTrigger.timer,
    this.intervalMinutes = 0,
    this.runAt,
    this.enabled = true,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get recurring => intervalMinutes > 0 && runAt == null;

  /// 下一次该跑的时刻（只跑一次的任务跑完即视为不再触发）。
  ///
  /// 消息触发型**没有「时刻」**（由 [AppState.addNewMessageListener] 唤醒），
  /// 返回 null，于是 [dueTasks] 天然不会把它当定时任务轮询到。
  DateTime? get nextRun {
    if (!enabled) return null;
    if (trigger == AgentTaskTrigger.message) return null;
    // 绝对时刻：只在「还没跑过」时到点触发。
    if (runAt != null) return lastRun == null ? runAt : null;
    if (!recurring) {
      return lastRun == null ? createdAt : null;
    }
    final base = lastRun ?? createdAt;
    return base.add(Duration(minutes: intervalMinutes));
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'prompt': prompt,
        'createdAt': createdAt.toIso8601String(),
        'lastRun': lastRun?.toIso8601String(),
        'trigger': trigger.name,
        'intervalMinutes': intervalMinutes,
        if (runAt != null) 'runAt': runAt!.toIso8601String(),
        'enabled': enabled,
      };

  static AgentTask? fromJson(Object? j) {
    if (j is! Map) return null;
    final prompt = '${j['prompt'] ?? ''}'.trim();
    if (prompt.isEmpty) return null;
    DateTime? dt(Object? v) =>
        v == null ? null : DateTime.tryParse('$v');
    return AgentTask(
      id: '${j['id'] ?? ''}',
      prompt: prompt,
      createdAt: dt(j['createdAt']),
      lastRun: dt(j['lastRun']),
      trigger: '${j['trigger']}' == AgentTaskTrigger.message.name
          ? AgentTaskTrigger.message
          : AgentTaskTrigger.timer,
      intervalMinutes:
          int.tryParse('${j['intervalMinutes']}') ?? 0,
      runAt: dt(j['runAt']),
      enabled: j['enabled'] != false,
    );
  }
}

/// 一条任务执行记录（供 `list_task_runs` 与排查「任务跑没跑成」）。
///
/// 此前任务只留 `lastRun` 一个时刻，跑成没跑成、结果是什么都查不到。这里存
/// 最近若干次的「什么时候、哪条任务、成没成、结果摘要」。
class AgentTaskRun {
  final String taskId;
  final String prompt;
  final DateTime at;
  final bool ok;
  final String summary;

  AgentTaskRun({
    required this.taskId,
    required this.prompt,
    required this.at,
    required this.ok,
    required this.summary,
  });

  Map<String, dynamic> toJson() => {
        'taskId': taskId,
        'prompt': prompt,
        'at': at.toIso8601String(),
        'ok': ok,
        'summary': summary,
      };

  static AgentTaskRun? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['at'] ?? ''}');
    if (at == null) return null;
    return AgentTaskRun(
      taskId: '${j['taskId'] ?? ''}',
      prompt: '${j['prompt'] ?? ''}',
      at: at,
      ok: j['ok'] == true,
      summary: '${j['summary'] ?? ''}',
    );
  }
}

/// 用户没自定义系统提示时用的默认提示。
///
/// 用英文写：各家用模型对英文系统提示的遵循度最稳；但明确要求它**用用户的语言
/// 回复**，否则中文用户会收到英文回答。提醒它只依据工具返回值作答、不要编造
/// 台站/消息数据，也不要夸大自己的能力。
const String kDefaultSystemPrompt = '''
You are the in-app assistant of APRSLocus, an APRS client. Help the user
understand and operate the app: answer questions and, when needed, call the
provided tools to read state, change settings, send messages or jump to a
screen.

Rules:
- Always reply in the SAME language the user writes in.
- BE PROACTIVE WITH TOOLS. Whenever an answer depends on current data (what is
  on the air, the user's settings, their chats, connectivity) or the user asks
  you to DO something, CALL THE TOOLS instead of answering from memory, guessing
  or asking the user to look it up themselves. Do not say "I cannot" or "I don't
  know" before you have tried the relevant tool — chain several tool calls when
  needed (read -> decide -> act), then summarise what you did.
- Before changing settings or sending anything, call `get_app_state` first to
  see the current values. Respect the allowed value ranges it returns.
- Never invent stations, messages or settings. Only state facts that came from
  a tool result; if you did not read it, say you do not know.
- Tools that change settings or send messages require the user's confirmation;
  explain briefly what you are about to do before calling them.
- Use `read_messages` to read the user's conversations and `list_stations` /
  `search_stations` / `nearby_stations` / `station_detail` to inspect what is on
  the air. These are read-only and never need confirmation.
- To answer an incoming message use `reply_message`; to talk to a whole group use
  `send_group_message` (find it with `list_groups`). `create_group` makes a new
  group. All of these need the "allow sending"/"allow settings" permission and
  the user's confirmation.
- You can create work that runs without the user watching, with `create_task`.
  `trigger` = "timer" (default) runs on a schedule (interval_minutes = 0 runs
  once, or pass `run_at` for an absolute ISO-8601 time); `trigger` = "message"
  runs the instruction each time a new APRS message arrives. A background run
  happens WITHOUT the user watching: only use it for things that are already
  permitted (e.g. reading and reporting), never for a one-off action that still
  needs a confirmation — that will just be denied. List existing tasks before
  creating one so you do not duplicate it. `update_task` edits one in place
  (prompt / trigger / schedule), `set_task_enabled` pauses or resumes it, and
  `list_task_runs` shows what actually ran.
- Groups, beyond listing: `update_group` renames a group or adds/removes members
  (`list_groups` shows the members and who is active), `join_group` /
  `leave_group` change your own membership, and `dismiss_group` deletes a group
  you own.
- Stations and data: `list_contacts` shows the user's followed stations,
  `set_favorite` follows/unfollows, and `set_station_ignored` hides a station
  from the map without stopping reception. `get_station_packets` returns recent
  raw frames (with the digipeater path), `get_track` / `export_track_gpx` give a
  station's track, and `distance_between` computes range/bearing between two
  stations or "me".
- Sensors and position: `get_sensors` reads heart rate, steps, battery, speed,
  course and mileage; `set_my_position` / `clear_my_position` set or clear a
  simulated position. `set_status_text` changes the station status text.
  `broadcast_message` sends the same message to several callsigns at once.
- Shared strategy map: a group can share markers, rally points, circles and
  lines that show up on every member's map. `list_strategy` lists a group's
  elements (read-only); `strategy_add_point` / `strategy_add_rally` /
  `strategy_add_circle` / `strategy_add_line` each add one and broadcast it to
  the group; `strategy_update` edits an element by its id, `strategy_delete`
  removes one, and `strategy_clear` wipes the whole layer. `strategy_request_snapshot`
  asks the members to re-send their elements (use it after joining a group to
  fill in the layer). Get an element's short id from `list_strategy` first;
  line/circle colours are a palette index 0..5. These tools send APRS frames, so
  they need the "allow sending"/"allow settings" permission and the user's
  confirmation.
- Permission awareness: `get_app_state` reports the current permissions
  (`allow_send`, `allow_settings`, notice acceptance). If a tool is refused for
  lack of permission, tell the user which switch to enable.
- You can help with connectivity: `set_connection_server` changes the APRS-IS
  server, `set_connection_source` enables/disables a link, and `connect` /
  `disconnect` bring the link up or down. Setting a server does NOT connect by
  itself. Only use a server address the user actually gave you — never make one
  up. If the user has not accepted the data & network usage notice, `connect`
  is refused; tell them to accept it in the app first.
- Long-term memory: when the user tells you something durable about themselves
  (a preference, their name, a callsign, a routine, a place they care about),
  call `save_memory` to keep it across conversations. Use `list_memories` to
  recall what you already know and `forget_memory` to drop a stale fact. Do not
  save transient details, secrets, or anything the user asks you to forget.
- Keep answers short and concrete.
''';

/// 智能体调用失败（消息已是可读文本）
class AgentException implements Exception {
  final String message;
  AgentException(this.message);
  @override
  String toString() => message;
}

/// 工具执行结果
class AgentToolOutcome {
  /// 回给模型的文本（成功或失败的说明）
  final String text;

  /// 界面上展示的一行摘要（可空）
  final String? note;

  const AgentToolOutcome(this.text, {this.note});
}

/// 执行一次工具调用。上层（[agent_tools.dart]）负责实现。
typedef AgentToolExecutor = Future<AgentToolOutcome> Function(
    String name, Map<String, dynamic> args);

/// 有副作用的工具执行前的确认结果。
enum AgentConfirmResult { deny, allowOnce, allowAlways }

/// 有副作用的工具执行前的确认。返回 [AgentConfirmResult]（deny / 仅此次 / 始终允许）。
typedef AgentToolConfirmer = Future<AgentConfirmResult> Function(
    String name, Map<String, dynamic> args);

/// 判断某个工具是否需要用户确认（由上层依据工具表决定，agent.dart 不认识工具表）。
typedef AgentNeedsConfirm = bool Function(String name);

/// 智能体服务：配置、历史与 LLM 调用循环（单例）
class AgentService extends ChangeNotifier {
  AgentService._();
  static final AgentService instance = AgentService._();

  static const _kConfig = 'agentConfigJson';
  static const _kHistory = 'agentChatHistoryJson';
  static const _kTasks = 'agentTasksJson';
  static const _kTaskRuns = 'agentTaskRunsJson';
  static const _kMemory = 'agentMemoryJson';
  static const _kSummary = 'agentHistorySummary';

  /// 单轮对话里工具调用的最大往返次数（防止模型死循环）
  static const int maxToolRounds = 6;

  /// 长期记忆条数上限 / 单条长度上限（注入系统提示，别把上下文撑爆）。
  static const int _kMaxMemories = 50;
  static const int _kMaxMemoryLen = 500;

  /// 存盘时保留的最近消息条数。够长以保留上下文，又不至于让磁盘/请求过大。
  static const int _kKeepMessages = 80;

  /// 触发压缩的阈值：消息数超过它就把较旧的一段折叠成摘要。
  static const int _kCompressThreshold = 40;

  /// 压缩后保留的最近消息条数（从这里往前切一段去摘要）。
  static const int _kCompressKeepRecent = 16;

  final AgentConfig config = AgentConfig();
  final List<AgentMessage> messages = [];

  /// 长期记忆（内存 + 磁盘）。智能体可用 `save_memory` 写入、`list_memories` 读、
  /// `forget_memory` 忘掉；开启 [AgentConfig.memoryEnabled] 时随系统提示注入。
  final List<AgentMemory> memories = [];

  /// 对话压缩出的历史摘要（可为空）。与 [messages] 一起注入系统提示。
  String historySummary = '';

  /// 定时任务（内存 + 磁盘）。
  final List<AgentTask> tasks = [];

  /// 任务执行记录（最新在前，最多 [_kMaxTaskRuns] 条）。
  final List<AgentTaskRun> taskRuns = [];
  static const int _kMaxTaskRuns = 100;

  bool loaded = false;
  bool busy = false;

  /// 流式回复中**已经收到**的正文（空 = 当前不在逐字流）。
  ///
  /// UI 直接渲染它 —— 字符一个一个出现就是靠这个。只在 [_chatStreaming]
  /// 期间非空；流结束 / 出错 / 取消都会清掉，随后由完整消息接管显示。
  String streamText = '';

  /// 自动回复冷却：会话 key（呼号/群）→ 上次自动回复时刻。
  final Map<String, DateTime> _autoReplyAt = {};

  /// 取消令牌：自增即让进行中的 [send] 在下一个检查点退出
  int _epoch = 0;

  /// 用「共享同一个 Future」实现幂等：并发的 [load]（例如冷启动时
  /// `AgentOverlay.initState` 与抢先到达的消息回调同时触发）都会等同一份
  /// 读取完成，而不是第二个调用看到 `loaded==true` 就立刻返回、拿着**空的**
  /// tasks/config 继续跑 —— 那正是「消息触发任务静默不触发」的根因之一。
  Future<void>? _loadFuture;

  Future<void> load() => _loadFuture ??= _loadFromDisk();

  Future<void> _loadFromDisk() async {
    try {
      final p = await SharedPreferences.getInstance();
      final c = p.getString(_kConfig);
      if (c != null && c.isNotEmpty) {
        _copy(AgentConfig.fromJson(jsonDecode(c)), config);
      }
      final h = p.getString(_kHistory);
      if (h != null && h.isNotEmpty) {
        final list = jsonDecode(h);
        if (list is List) {
          for (final m in list) {
            if (m is Map) messages.add(AgentMessage.fromJson(m));
          }
        }
      }
      final tk = p.getString(_kTasks);
      if (tk != null && tk.isNotEmpty) {
        final list = jsonDecode(tk);
        if (list is List) {
          for (final t in list) {
            final task = AgentTask.fromJson(t);
            if (task != null) tasks.add(task);
          }
        }
      }
      final tr = p.getString(_kTaskRuns);
      if (tr != null && tr.isNotEmpty) {
        final list = jsonDecode(tr);
        if (list is List) {
          for (final r in list) {
            final run = AgentTaskRun.fromJson(r);
            if (run != null) taskRuns.add(run);
          }
        }
      }
      final mem = p.getString(_kMemory);
      if (mem != null && mem.isNotEmpty) {
        final list = jsonDecode(mem);
        if (list is List) {
          for (final m in list) {
            final e = AgentMemory.fromJson(m);
            if (e != null) memories.add(e);
          }
        }
      }
      historySummary = p.getString(_kSummary) ?? '';
    } catch (_) {}
    loaded = true;
    notifyListeners();
  }

  Future<void> _saveMemories() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          _kMemory, jsonEncode(memories.map((m) => m.toJson()).toList()));
    } catch (_) {}
  }

  Future<void> _saveSummary() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kSummary, historySummary);
    } catch (_) {}
  }

  /// 记住一条事实（去重：文本相同则不重复添加，但会刷新到最新）。
  /// 返回 true = 新增，false = 已存在（刷新）。
  Future<bool> addMemory(String text) async {
    final t = text.trim();
    if (t.isEmpty) return false;
    final capped = t.length > _kMaxMemoryLen ? t.substring(0, _kMaxMemoryLen) : t;
    final dup = memories.where((m) => m.text == capped).firstOrNull;
    if (dup != null) {
      memories.remove(dup);
      memories.add(dup); // 挪到末尾视作最新
      await _saveMemories();
      notifyListeners();
      return false;
    }
    memories.add(AgentMemory(
      id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      text: capped,
      at: DateTime.now(),
    ));
    // 超出上限丢最旧的，避免无限增长。
    while (memories.length > _kMaxMemories) {
      memories.removeAt(0);
    }
    await _saveMemories();
    notifyListeners();
    return true;
  }

  /// 按 id 或文本子串删除记忆；返回删除条数。
  Future<int> forgetMemory(String key) async {
    final k = key.trim().toLowerCase();
    if (k.isEmpty) return 0;
    final before = memories.length;
    memories.removeWhere((m) =>
        m.id == key.trim() || m.text.toLowerCase().contains(k));
    final removed = before - memories.length;
    if (removed > 0) {
      await _saveMemories();
      notifyListeners();
    }
    return removed;
  }

  Future<void> clearMemories() async {
    memories.clear();
    await _saveMemories();
    notifyListeners();
  }

  static void _copy(AgentConfig from, AgentConfig to) {
    to
      ..enabled = from.enabled
      ..baseUrl = from.baseUrl
      ..apiKey = from.apiKey
      ..model = from.model
      ..systemPrompt = from.systemPrompt
      ..allowSend = from.allowSend
      ..allowSettings = from.allowSettings
      ..alwaysAllow = {...from.alwaysAllow}
      ..autoReply = from.autoReply
      ..replyGroups = from.replyGroups
      ..autoReplyCooldownSec = from.autoReplyCooldownSec
      ..quietHours = from.quietHours
      ..allowNetwork = from.allowNetwork
      ..memoryEnabled = from.memoryEnabled
      ..compressEnabled = from.compressEnabled;
  }

  Future<void> saveConfig() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kConfig, jsonEncode(config.toJson()));
    } catch (_) {}
    notifyListeners();
  }

  Future<void> saveTasks() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          _kTasks, jsonEncode(tasks.map((t) => t.toJson()).toList()));
    } catch (_) {}
    notifyListeners();
  }

  /// 新增一个任务并落盘，返回它。
  Future<AgentTask> addTask(
    String prompt, {
    AgentTaskTrigger trigger = AgentTaskTrigger.timer,
    int intervalMinutes = 0,
  }) async {
    final t = AgentTask(
      id: 't${DateTime.now().microsecondsSinceEpoch}',
      prompt: prompt.trim(),
      trigger: trigger,
      intervalMinutes: intervalMinutes < 0 ? 0 : intervalMinutes,
    );
    tasks.add(t);
    await saveTasks();
    return t;
  }

  Future<void> removeTask(String id) async {
    tasks.removeWhere((t) => t.id == id);
    await saveTasks();
  }

  /// 就地修改一个任务（只改传入的字段）。返回是否找到该任务。
  Future<bool> updateTask(
    String id, {
    String? prompt,
    AgentTaskTrigger? trigger,
    int? intervalMinutes,
    DateTime? runAt,
    bool clearRunAt = false,
  }) async {
    final t = tasks.where((t) => t.id == id).firstOrNull;
    if (t == null) return false;
    if (prompt != null && prompt.trim().isNotEmpty) t.prompt = prompt.trim();
    if (trigger != null) t.trigger = trigger;
    if (runAt != null) {
      t.runAt = runAt;
      // 绝对时刻优先于循环间隔：设了 run_at 就当作「只跑一次」。
      t.intervalMinutes = 0;
    } else if (clearRunAt) {
      t.runAt = null;
    }
    if (intervalMinutes != null) {
      t.intervalMinutes = intervalMinutes < 0 ? 0 : intervalMinutes;
      t.runAt = null; // 设了间隔就以间隔为准
    }
    // 改完触发方式/时间后，让「下一次」从头算：否则旧的 lastRun 会让循环
    // 任务在新间隔下等一个已经过去的点，或只跑一次的任务误判为已跑过。
    t.lastRun = null;
    t.enabled = true;
    await saveTasks();
    return true;
  }

  /// 记一条任务执行结果（保留最近 [_kMaxTaskRuns] 条，最新在前）。
  Future<void> recordTaskRun(
      String taskId, String prompt, bool ok, String summary) async {
    taskRuns.insert(
      0,
      AgentTaskRun(
        taskId: taskId,
        prompt: prompt,
        at: DateTime.now(),
        ok: ok,
        summary: summary,
      ),
    );
    if (taskRuns.length > _kMaxTaskRuns) {
      taskRuns.removeRange(_kMaxTaskRuns, taskRuns.length);
    }
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          _kTaskRuns, jsonEncode(taskRuns.map((r) => r.toJson()).toList()));
    } catch (_) {}
    notifyListeners();
  }

  /// 某个任务的执行记录（最新在前）。[taskId] 为空时返回全部。
  List<AgentTaskRun> taskRunsFor(String taskId) => taskId.isEmpty
      ? List.unmodifiable(taskRuns)
      : [for (final r in taskRuns) if (r.taskId == taskId) r];

  /// 清除某个任务（或全部）的执行记录。
  Future<void> clearTaskRuns(String taskId) async {
    if (taskId.isEmpty) {
      taskRuns.clear();
    } else {
      taskRuns.removeWhere((r) => r.taskId == taskId);
    }
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          _kTaskRuns, jsonEncode(taskRuns.map((r) => r.toJson()).toList()));
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setTaskEnabled(String id, bool on) async {
    final t = tasks.where((t) => t.id == id).firstOrNull;
    if (t == null) return;
    t.enabled = on;
    await saveTasks();
  }

  /// 标一个任务已跑过（循环任务据此顺延下一次）。
  Future<void> markTaskRun(String id) async {
    final t = tasks.where((t) => t.id == id).firstOrNull;
    if (t == null) return;
    t.lastRun = DateTime.now();
    // 只跑一次的任务跑完即停用（不再触发），但保留列表让用户看到它跑过。
    if (!t.recurring) t.enabled = false;
    await saveTasks();
  }

  /// 消息触发型任务被唤醒时，只更新「上次运行」时间戳（供用户排查
  /// 「到底跑没跑」，报告里 `last_run=null` 就是最直接的证据）。
  ///
  /// 不能复用 [markTaskRun]：那个会把**非循环**任务直接停用，而消息任务
  /// 正是非循环的（`recurring == false`），一用就被永久关掉。
  Future<void> touchTaskRun(String id) async {
    final t = tasks.where((t) => t.id == id).firstOrNull;
    if (t == null) return;
    t.lastRun = DateTime.now();
    await saveTasks();
    notifyListeners();
  }

  /// 到点该跑的任务（在 [now] 之前应触发且仍启用）。
  List<AgentTask> dueTasks(DateTime now) =>
      [for (final t in tasks) if (t.nextRun != null && !t.nextRun!.isAfter(now)) t];

  /// 收到消息时要跑的任务（已启用 + 触发源为 message）。抽出来便于单测：
  /// 这条路径的闸门独立于自动回复（见 `_onIncoming`）。
  List<AgentTask> messageTasks() => [
        for (final t in tasks)
          if (t.enabled && t.trigger == AgentTaskTrigger.message) t
      ];

  Future<void> saveHistory() async {
    try {
      final p = await SharedPreferences.getInstance();
      // 只留最近 [_kKeepMessages] 条。**必须从一个 user 消息开始**：OpenAI 要求
      // assistant 的每个 tool_calls 都紧跟对应的 tool 回复；若裁剪边界正好落在
      // 中间，留下一条孤立的 tool 消息，下一次请求会整段报错（很难查的 400）。
      var start = messages.length > _kKeepMessages
          ? messages.length - _kKeepMessages
          : 0;
      while (start < messages.length && messages[start].role != 'user') {
        start++;
      }
      final recent = messages.sublist(start);
      await p.setString(
          _kHistory, jsonEncode(recent.map((m) => m.toJson()).toList()));
    } catch (_) {}
  }

  Future<void> clearHistory() async {
    messages.clear();
    historySummary = '';
    await saveHistory();
    await _saveSummary();
    notifyListeners();
  }

  /// 手动「压缩对话」：把除最近 [_kCompressKeepRecent] 条以外的历史折叠进摘要，
  /// 然后删掉那部分。返回是否真的压缩了（没什么可压时返回 false）。
  Future<bool> compressNow({String instructions = ''}) async {
    if (messages.length <= _kCompressKeepRecent) return false;
    String keep;
    try {
      keep = await _summarize(instructions: instructions);
    } on AgentException {
      rethrow;
    } catch (e) {
      throw AgentException('$e');
    }
    if (keep.trim().isEmpty) return false;
    historySummary = keep.trim();
    final drop = messages.length - _kCompressKeepRecent;
    _compressOldMessages(drop);
    await _saveSummary();
    await saveHistory();
    notifyListeners();
    return true;
  }

  /// 把最旧的 [count] 条从历史里移除（用摘要替代），不触发网络。
  void _compressOldMessages(int count) {
    if (count <= 0 || count >= messages.length) return;
    messages.removeRange(0, count);
  }

  /// 历史过长时自动压缩（存盘前调用；失败就放弃，不影响正常对话）。
  Future<void> _maybeAutoCompress() async {
    if (!config.compressEnabled) return;
    if (messages.length <= _kCompressThreshold) return;
    try {
      final keep = await _summarize();
      if (keep.trim().isEmpty) return;
      historySummary = keep.trim();
      // 只丢到「保留最近 _kCompressKeepRecent 条」，剩下的自然留白。
      _compressOldMessages(messages.length - _kCompressKeepRecent);
      await _saveSummary();
      await saveHistory();
      notifyListeners();
    } catch (_) {
      // 压缩是「锦上添花」：模型/网络出问题也不能影响用户正在用的对话。
    }
  }

  /// 让模型把「当前全部历史 + 已有摘要」折叠成一段不超过约 200 字的中文摘要。
  Future<String> _summarize({String instructions = ''}) async {
    final sb = StringBuffer();
    if (historySummary.trim().isNotEmpty) {
      sb.writeln('Existing summary:\n${historySummary.trim()}\n');
    }
    sb.writeln('Conversation to fold in:');
    for (final m in messages) {
      final role = switch (m.role) {
        'user' => 'User',
        'assistant' => 'Assistant',
        _ => 'Tool(${m.name ?? ''})',
      };
      final c = m.content.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (c.isEmpty && m.toolCalls.isEmpty) continue;
      final tc = m.toolCalls.isEmpty
          ? ''
          : ' [tools: ${m.toolCalls.map((t) => t.name).join(', ')}]';
      final line = c.length > 300 ? '${c.substring(0, 300)}…' : c;
      sb.writeln('$role: $line$tc');
    }
    if (instructions.trim().isNotEmpty) {
      sb.writeln('\nExtra focus: ${instructions.trim()}');
    }
    final body = <String, dynamic>{
      'model': config.model.trim(),
      'messages': [
        {
          'role': 'system',
          'content': 'You compress chat history for a personal APRS assistant. '
              'Produce a concise summary (<=200 words) capturing the user\'s '
              'goals, preferences, decisions, important facts (callsigns, '
              'places, settings) and any pending items. Plain text, keep names '
              'and numbers exact, no preamble.',
        },
        {'role': 'user', 'content': sb.toString()},
      ],
      'temperature': 0.2,
      'max_tokens': 500,
    };
    final resp = await httpSend(
      'POST',
      Uri.parse(config.endpoint),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${config.apiKey.trim()}',
      },
      body: jsonEncode(body),
      timeout: const Duration(seconds: 60),
    );
    final data = jsonDecode(resp);
    if (data is! Map) throw AgentException('Unexpected response');
    final choices = data['choices'];
    if (choices is! List || choices.isEmpty) return '';
    final msg = (choices.first as Map)['message'];
    if (msg is! Map) return '';
    return '${msg['content'] ?? ''}'.trim();
  }

  /// 恢复出厂：清配置与历史（只动内存，磁盘由 AppState.factoryReset 统一清）
  void resetToDefaults() {
    _copy(AgentConfig(), config);
    messages.clear();
    memories.clear();
    historySummary = '';
    tasks.clear();
    taskRuns.clear();
    _autoReplyAt.clear();
    busy = false;
  }

  /// 自动回复是否可用（权限 + 开关 + 不在安静时段）。
  bool canAutoReply(DateTime now) =>
      config.enabled && config.autoReply && !inQuietHours(now);

  /// [now] 是否落在 [AgentConfig.quietHours] 指定的安静时段内。
  bool inQuietHours(DateTime now) {
    final r = _parseQuiet(config.quietHours);
    if (r == null) return false;
    final m = now.hour * 60 + now.minute;
    final (a, b) = r;
    return a <= b ? (m >= a && m < b) : (m >= a || m < b); // 后者=跨零点
  }

  /// 解析 `HH:MM-HH:MM` → (起始分钟, 结束分钟)；非法返回 null。
  static (int, int)? _parseQuiet(String s) {
    final m =
        RegExp(r'^\s*(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})\s*$').firstMatch(s);
    if (m == null) return null;
    int h(int i) => int.parse(m.group(i)!);
    int mi(int i) => int.parse(m.group(i + 1)!);
    final a = h(1) * 60 + mi(1);
    final b = h(3) * 60 + mi(3);
    if (a >= 1440 || b > 1440) return null;
    return (a, b);
  }

  /// 记录一次自动回复并判断是否已过冷却。
  bool autoReplyAllowed(String convoKey, DateTime now) {
    final last = _autoReplyAt[convoKey];
    if (last != null &&
        now.difference(last).inSeconds < config.autoReplyCooldownSec) {
      return false;
    }
    _autoReplyAt[convoKey] = now;
    return true;
  }

  /// 中止进行中的对话
  void cancel() {
    _epoch++;
    busy = false;
    // 半截正文也要丢掉：否则取消后气泡还挂着「写到一半」的一段。
    streamText = '';
    notifyListeners();
  }

  /// 发一条用户消息并跑完整个「模型 ↔ 工具」循环。
  ///
  /// [tools] 是给模型的工具 schema（OpenAI tools 格式）；
  /// [execute] 真正执行某个工具；[confirm] 在「有副作用」的工具执行前询问用户，
  /// 返回 false 则不执行（并把「被拒绝」作为工具结果回给模型）。
  Future<void> send(
    String text, {
    required List<Map<String, dynamic>> tools,
    required AgentToolExecutor execute,
    required AgentToolConfirmer confirm,
    required AgentNeedsConfirm needsConfirm,
    required String needConfigText,
    required String Function(String raw) formatError,
  }) async {
    final t = text.trim();
    if (t.isEmpty || busy) return;
    if (!config.ready) {
      throw AgentException(needConfigText);
    }
    final my = ++_epoch;
    busy = true;
    messages.add(AgentMessage(role: 'user', content: t));
    notifyListeners();

    try {
      // 有些模型（尤其是小模型）会「聊一句」就收尾、明明该查数据却不调工具。
      // 头一轮若一个工具都没调，就**再要一轮**并临时把 tool_choice 设成
      // required，逼它先取一次数据 / 执行动作；只逼这一次，之后回到 auto，
      // 免得把每一句寒暄都变成工具调用。
      var nudged = false;
      for (var round = 0; round < maxToolRounds; round++) {
        if (_epoch != my) return; // 被取消
        final force = !nudged && tools.isNotEmpty;
        // 只在本轮「逼」；下轮起回到 auto（否则模型永远给不出最终回答，
        // 会一路调到 maxToolRounds 也没有收尾）。
        nudged = true;
        AgentMessage reply;
        try {
          reply = await _chat(tools, requireTool: force);
        } on AgentException {
          // 有的 OpenAI 兼容后端不认 tool_choice:"required"：退回 auto 再试一次，
          // 不能因为「强制」这一步失败就把整轮对话搞挂。
          if (!force) rethrow;
          reply = await _chat(tools);
        }
        if (_epoch != my) return;
        final calls = reply.toolCalls;

        if (calls.isEmpty && force) {
          // 被强制却仍没调工具（少见）：收下这条回复，当普通回答结束本轮。
          messages.add(reply);
          notifyListeners();
          break;
        }

        messages.add(reply);
        notifyListeners();

        if (calls.isEmpty) break;

        for (final call in calls) {
          // 取消后不再执行，但**仍要**为每个 tool_call 补一条 tool 消息：
          // OpenAI 要求 assistant 里的每个 tool_calls 都有对应回复，缺一条
          // 会让下一次请求整段历史上报错。
          if (_epoch != my) {
            messages.add(AgentMessage(
              role: 'tool',
              content: 'Canceled by user.',
              toolCallId: call.id,
              name: call.name,
            ));
            continue;
          }
          var result = '';
          // 免确认判定交给上层（它知道工具表）：只读工具、navigate，或用户已在
          // 「始终允许」名单里放行的工具，都直接执行。
          final needsAsk =
              needsConfirm(call.name) && !config.alwaysAllow.contains(call.name);
          if (needsAsk) {
            final decision = await confirm(call.name, call.arguments);
            if (decision == AgentConfirmResult.deny) {
              result = 'User denied this action.';
            } else {
              if (decision == AgentConfirmResult.allowAlways) {
                config.alwaysAllow.add(call.name);
                unawaited(saveConfig());
              }
              final outcome = await execute(call.name, call.arguments);
              result = outcome.text;
            }
          } else {
            final outcome = await execute(call.name, call.arguments);
            result = outcome.text;
          }
          messages.add(AgentMessage(
            role: 'tool',
            content: result,
            toolCallId: call.id,
            name: call.name,
          ));
          notifyListeners();
        }
        if (_epoch != my) return;
      }
    } catch (e) {
      messages.add(AgentMessage(
        role: 'assistant',
        content: formatError('$e'),
      ));
    } finally {
      if (_epoch == my) busy = false;
      notifyListeners();
      unawaited(saveHistory());
      // 历史变长后自动折叠旧对话（失败静默；见 [_maybeAutoCompress]）。
      if (_epoch == my) unawaited(_maybeAutoCompress());
    }
  }

  /// 组装发给模型的消息数组
  List<Map<String, dynamic>> _wireMessages() {
    final out = <Map<String, dynamic>>[];
    // 用户没写系统提示时用内置默认：否则模型没有任何角色设定，工具用了也不解释、
    // 甚至可能编造台站数据。用户填了就以用户的为准。
    final sp = config.systemPrompt.trim().isEmpty
        ? kDefaultSystemPrompt
        : config.systemPrompt.trim();
    out.add({'role': 'system', 'content': '$sp${_contextBlock()}'});
    for (final m in messages) {
      out.add(m.toJson());
    }
    return out;
  }

  /// 拼在系统提示后面的「长期记忆 + 历史摘要」块（都为空时返回空串）。
  ///
  /// 注入在这里而不是历史里：摘要 / 记忆是**背景知识**，不是对话轮次，
  /// 放系统提示里既不会破坏 tool_call 配对，用户清理对话时也仍在。
  String _contextBlock() {
    final b = StringBuffer();
    if (config.memoryEnabled && memories.isNotEmpty) {
      b.writeln('\n\n## Long-term memory (facts you chose to remember about '
          'this user; treat as true, keep obeying them)');
      for (final m in memories) {
        b.writeln('- ${m.text}');
      }
    }
    if (historySummary.trim().isNotEmpty) {
      b.writeln('\n\n## Summary of earlier conversation (older turns were '
          'folded to save space; use for context)');
      b.writeln(historySummary.trim());
    }
    return b.toString();
  }

  /// 调一次 chat/completions，返回助手消息（可能带 tool_calls）
  ///
  /// [requireTool] = true 时用 `tool_choice: "required"` 强制模型这一步必须调
  /// 工具（见 [send] 里的「主动调工具」nudge）；默认 `"auto"`。
  ///
  /// 开了逐字回复就先走流式，拿不到流再退回整段 —— 两条路产出的
  /// [AgentMessage] 完全同形，上层（[send] / 工具循环）感知不到差别。
  Future<AgentMessage> _chat(List<Map<String, dynamic>> tools,
      {bool requireTool = false}) async {
    final my = _epoch;
    final body = <String, dynamic>{
      'model': config.model.trim(),
      'messages': _wireMessages(),
      if (tools.isNotEmpty) 'tools': tools,
      if (tools.isNotEmpty)
        'tool_choice': requireTool ? 'required' : 'auto',
      'temperature': 0.3,
    };
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${config.apiKey.trim()}',
    };
    final raw = jsonEncode(body);
    if (config.streamReply) {
      final streamed = await _chatStreaming(headers, raw);
      // 被取消时 [send] 马上就会 return，这里返回什么都不会进历史。
      if (_epoch != my) return AgentMessage(role: 'assistant');
      if (streamed != null) return streamed;
    }
    final reply = await _chatOnce(headers, raw);
    // 后端不支持流式（回到这里）时，用打字机补上「逐字」的观感：
    // 关掉逐字回复的开关（config.streamReply=false）就整段直接出现，不再补。
    if (config.streamReply) await _typeOut(reply);
    return reply;
  }

  /// 打字机：把**已经到手**的整段正文逐字吐出来（给 [streamText]）。
  ///
  /// 只有「请求了流式但后端不认」这条路才会用到它 —— 真正的流式是模型边生成
  /// 边到的，再动一次反而像卡顿。每 ~20ms 吐一小段、总时长压在 ~1.2 秒内：
  /// 短句看起来就是在打字，长回答也不会让人干等 —— 按字符数线性吐字的话，
  /// 800 字的回复要「写」十几秒，比直接显示更难受。
  Future<void> _typeOut(AgentMessage reply) async {
    final text = reply.content;
    if (text.trim().isEmpty) return; // 只有 tool_calls 的一轮：没有正文可吐
    final my = _epoch;
    final total = text.length;
    final steps = (total ~/ 3).clamp(12, 60);
    final per = (total / steps).ceil();
    try {
      for (var end = per; end <= total; end += per) {
        if (_epoch != my) return; // 用户点了停止
        streamText = text.substring(0, end);
        notifyListeners();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    } finally {
      // 收干净：留着半截会让下一个气泡先显示上一轮的残句。清理与「并入历史」
      // 之间只隔一个微任务（send 里 messages.add），不会渲染出中间帧。
      streamText = '';
      if (_epoch == my) notifyListeners();
    }
  }

  /// 流式调一次：边收边把正文写进 [streamText]（UI 因此能「逐字」显示）。
  ///
  /// 返回 null = 这次流式**一个字节的内容都没拿到**，通常意味着后端忽略了
  /// `stream:true`、直接回了一整段普通 JSON（不是合法的 SSE），调用方据此
  /// 退回 [_chatOnce]。真正的错误（HTTP 状态 / 平台不支持 / 服务端 error）
  /// 照常抛 [AgentException]。
  Future<AgentMessage?> _chatStreaming(
      Map<String, String> headers, String body) async {
    final my = _epoch;
    final asm = AgentStreamAssembler();
    streamText = '';
    var lastNotify = 0;
    try {
      await for (final line in httpSendLines(
        'POST',
        Uri.parse(config.endpoint),
        headers: headers,
        body: body,
        // 空闲超时：长回答写几分钟都正常，但两片之间静了 60 秒就是链路死了。
        timeout: const Duration(seconds: 60),
      )) {
        if (_epoch != my) return null; // 被取消：立刻停止收流
        if (!asm.feed(line)) continue;
        streamText = asm.text;
        // 节流：一片一个 token，长回答能到每秒几十片；每片都 notifyListeners
        // 会让整页（列表 / 输入框 / 头像）跟着每帧重建。60ms 既省又能保持
        // 「逐字」的观感。
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastNotify >= 60) {
          lastNotify = now;
          notifyListeners();
        }
      }
    } on HttpStatusError catch (e) {
      throw AgentException('HTTP ${e.status}: ${_brief(e.body)}');
    } on UnsupportedError {
      // Web 构建里 httpSendLines 明确不支持（CORS），给一句人话。
      throw AgentException(
          'Network requests are not supported on this platform.');
    } on TimeoutException {
      throw AgentException('Stream timed out');
    } catch (e) {
      throw AgentException('$e');
    } finally {
      // 无论怎么结束都要收干净：留着半截正文会让下一个气泡「先显示上一轮的
      // 残句」，看起来像串台。
      streamText = '';
      if (_epoch == my) notifyListeners();
    }
    if (asm.error != null) throw AgentException(asm.error!);
    if (asm.isEmpty) return null;
    return asm.build();
  }

  /// 整段式调一次（老路径）：等响应体收完再解析。
  ///
  /// 留着它有两个用途：关闭逐字回复时走这里；后端不支持流式时的兜底。
  Future<AgentMessage> _chatOnce(
      Map<String, String> headers, String body) async {
    String resp;
    try {
      resp = await httpSend(
        'POST',
        Uri.parse(config.endpoint),
        headers: headers,
        body: body,
        timeout: const Duration(seconds: 60),
      );
    } on HttpStatusError catch (e) {
      throw AgentException('HTTP ${e.status}: ${_brief(e.body)}');
    } on UnsupportedError {
      // Web 构建里 httpSend 明确不支持（CORS），给一句人话而不是裸的异常名。
      throw AgentException(
          'Network requests are not supported on this platform.');
    } catch (e) {
      throw AgentException('$e');
    }
    final data = jsonDecode(resp);
    if (data is! Map) throw AgentException('Unexpected response');
    final err = data['error'];
    if (err != null) {
      final msg = err is Map ? (err['message'] ?? err) : err;
      throw AgentException('$msg');
    }
    final choices = data['choices'];
    if (choices is! List || choices.isEmpty) {
      throw AgentException('Empty response');
    }
    final msg = (choices.first as Map)['message'];
    if (msg is! Map) throw AgentException('Empty message');
    return AgentMessage(
      role: 'assistant',
      content: '${msg['content'] ?? ''}',
      toolCalls: [
        for (final c in (msg['tool_calls'] as List? ?? const []))
          if (c is Map) AgentToolCall.fromJson(c),
      ],
    );
  }

  /// 「测试连接」：发一条最短的对话，成功返回模型返回的文本片段。
  Future<String> testConnection() async {
    if (!config.ready) {
      throw AgentException('Incomplete configuration');
    }
    final old = _epoch;
    final body = {
      'model': config.model.trim(),
      'messages': const [
        {'role': 'user', 'content': 'ping'},
      ],
      'max_tokens': 8,
    };
    String resp;
    try {
      resp = await httpSend(
        'POST',
        Uri.parse(config.endpoint),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${config.apiKey.trim()}',
        },
        body: jsonEncode(body),
        timeout: const Duration(seconds: 30),
      );
    } on HttpStatusError catch (e) {
      // 把服务端的报错正文带出来（Key 错 / 模型名错都能一眼看出）
      throw AgentException('HTTP ${e.status}: ${_brief(e.body)}');
    } catch (e) {
      throw AgentException('$e');
    }
    if (_epoch != old) return config.model;
    final data = jsonDecode(resp);
    if (data is Map) {
      final choices = data['choices'];
      if (choices is List && choices.isNotEmpty) {
        final msg = (choices.first as Map)['message'];
        if (msg is Map && '${msg['content']}'.trim().isNotEmpty) {
          return '${msg['content']}'.trim();
        }
      }
    }
    return config.model;
  }

  static String _brief(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > 160 ? '${t.substring(0, 160)}…' : t;
  }
}
